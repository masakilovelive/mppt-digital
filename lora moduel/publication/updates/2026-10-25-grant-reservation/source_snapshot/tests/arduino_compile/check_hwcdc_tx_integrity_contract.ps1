param(
  [string]$ArduinoCli,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedCoreVersion = '3.3.11',
  [string]$IdeConfig = (Join-Path $env:USERPROFILE '.arduinoIDE\arduino-cli.yaml'),
  [string]$InstalledEsp32CoreRoot = '',
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-HWCDC-TX-INTEGRITY-001'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$canonicalRoot = Join-Path $repoRoot `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32'
$canonicalHwcdcPath = Join-Path $canonicalRoot 'HWCDC.cpp'
$canonicalHwcdcHeaderPath = Join-Path $canonicalRoot 'HWCDC.h'
$canonicalDiagnosticHeaderPath = Join-Path $canonicalRoot `
  'HWCDCR19Diagnostic.h'

if (-not $ArduinoCli) {
  $ArduinoCli = Join-Path $env:TEMP 'arduino-cli-vc-lora-check\arduino-cli.exe'
}
if (-not $OutputDir) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $OutputDir = Join-Path $repoRoot "runs\contracts\$testId"
}

$failures = [Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) {
  $script:failures.Add($Message)
  Write-Host "FAIL: $Message"
}

function Get-FunctionBody([string]$Text, [string]$SignaturePattern) {
  $match = [regex]::Match($Text, $SignaturePattern)
  if (-not $match.Success) { return $null }
  $open = $Text.IndexOf('{', $match.Index + $match.Length)
  if ($open -lt 0) { return $null }
  $depth = 0
  for ($index = $open; $index -lt $Text.Length; ++$index) {
    if ($Text[$index] -eq '{') { ++$depth }
    elseif ($Text[$index] -eq '}') {
      --$depth
      if ($depth -eq 0) {
        return $Text.Substring($open + 1, $index - $open - 1)
      }
    }
  }
  return $null
}

function Remove-CppComments([string]$Text) {
  if ($null -eq $Text) { return $null }
  # New safety assertions must be satisfied by executable source, not by a
  # design note which happens to mention the expected token. Preserve line
  # breaks so diagnostics and function slicing remain understandable.
  $withoutBlocks = [regex]::Replace(
      $Text, '/\*[\s\S]*?\*/', { param($match) ($match.Value -replace '[^\r\n]', '') })
  return [regex]::Replace($withoutBlocks, '(?m)//[^\r\n]*', '')
}

function Get-SecondCallArgument(
    [string]$Text, [string]$FunctionName) {
  if ($null -eq $Text) { return $null }
  $match = [regex]::Match(
      $Text,
      ('\b' + [regex]::Escape($FunctionName) +
       '\s*\(\s*[^,()]+\s*,\s*(?<argument>[^,()]+?)\s*\)'))
  if (-not $match.Success) { return $null }
  return $match.Groups['argument'].Value.Trim()
}

function Test-CleanResetCause([string]$Argument) {
  if ([string]::IsNullOrWhiteSpace($Argument)) { return $false }
  return $Argument -match
      '^(?:false|[^;]*(?:clean|entry|prewrite|before_fifo|no_fifo|safe)[^;]*)$'
}

$startedUtc = (Get-Date).ToUniversalTime()
$boardVersion = $null
$hwcdcPath = $null
$hwcdcHeaderPath = $null
$diagnosticHeaderPath = $null
$hwcdcPathSource = $null
$hwcdcSha256 = $null
$hwcdcHeaderSha256 = $null
$diagnosticHeaderSha256 = $null
$canonicalHwcdcSha256 = $null
$canonicalHwcdcHeaderSha256 = $null
$canonicalDiagnosticHeaderSha256 = $null
$checks = [Collections.Generic.List[object]]::new()

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$summaryPath = Join-Path $OutputDir 'summary.json'

try {
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    throw "Arduino CLI not found: $ArduinoCli"
  }

  $globalArgs = @()
  if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
    $globalArgs += @('--config-file', $IdeConfig)
  }
  $board = (& $ArduinoCli @globalArgs board details --fqbn $Fqbn `
      --format json | ConvertFrom-Json)
  $boardVersion = [string]$board.version
  $versionExact = $boardVersion -ceq $ExpectedCoreVersion
  $checks.Add([pscustomobject][ordered]@{
      name='esp32_core_version_exact';expected=$ExpectedCoreVersion
      actual=$boardVersion;valid=$versionExact
    })
  if (-not $versionExact) {
    Add-Failure "expected ESP32 core $ExpectedCoreVersion, got $boardVersion"
  }

  $corePathProperty = @($board.build_properties | Where-Object {
      $_ -like 'build.core.path=*'
    } | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($InstalledEsp32CoreRoot)) {
    $corePath = Join-Path (Resolve-Path -LiteralPath $InstalledEsp32CoreRoot `
        -ErrorAction Stop).Path 'cores\esp32'
    $hwcdcPath = Join-Path $corePath 'HWCDC.cpp'
    $hwcdcHeaderPath = Join-Path $corePath 'HWCDC.h'
    $diagnosticHeaderPath = Join-Path $corePath 'HWCDCR19Diagnostic.h'
    $hwcdcPathSource = 'explicit_installed_core_root'
  } elseif ($corePathProperty.Count -eq 1) {
    $corePath = ([string]$corePathProperty[0]).Substring(
      ([string]$corePathProperty[0]).IndexOf('=') + 1)
    $hwcdcPath = Join-Path $corePath 'HWCDC.cpp'
    $hwcdcHeaderPath = Join-Path $corePath 'HWCDC.h'
    $diagnosticHeaderPath = Join-Path $corePath 'HWCDCR19Diagnostic.h'
    $hwcdcPathSource = 'board_details_build_core_path'
  } else {
    $fallbackCorePath = Join-Path $env:LOCALAPPDATA `
        "Arduino15\packages\esp32\hardware\esp32\$boardVersion\cores\esp32"
    $hwcdcPath = Join-Path $fallbackCorePath 'HWCDC.cpp'
    $hwcdcHeaderPath = Join-Path $fallbackCorePath 'HWCDC.h'
    $diagnosticHeaderPath = Join-Path $fallbackCorePath `
      'HWCDCR19Diagnostic.h'
    $hwcdcPathSource = 'localappdata_fallback'
  }
  if (-not (Test-Path -LiteralPath $hwcdcPath -PathType Leaf)) {
    throw "installed HWCDC source not found: $hwcdcPath"
  }
  if (-not (Test-Path -LiteralPath $hwcdcHeaderPath -PathType Leaf)) {
    throw "installed HWCDC header not found: $hwcdcHeaderPath"
  }
  if (-not (Test-Path -LiteralPath $diagnosticHeaderPath -PathType Leaf)) {
    throw "installed HWCDC diagnostic header not found: $diagnosticHeaderPath"
  }
  $hwcdcText = Get-Content -LiteralPath $hwcdcPath -Raw
  $hwcdcHeaderText = Get-Content -LiteralPath $hwcdcHeaderPath -Raw
  $diagnosticHeaderText = Get-Content -LiteralPath $diagnosticHeaderPath -Raw
  $hwcdcCode = Remove-CppComments $hwcdcText
  $hwcdcHeaderCode = Remove-CppComments $hwcdcHeaderText
  $diagnosticHeaderCode = Remove-CppComments $diagnosticHeaderText
  $hwcdcSha256 = (Get-FileHash -LiteralPath $hwcdcPath -Algorithm SHA256).Hash
  $hwcdcHeaderSha256 =
      (Get-FileHash -LiteralPath $hwcdcHeaderPath -Algorithm SHA256).Hash
  $diagnosticHeaderSha256 =
      (Get-FileHash -LiteralPath $diagnosticHeaderPath -Algorithm SHA256).Hash

  if (-not (Test-Path -LiteralPath $canonicalHwcdcPath -PathType Leaf)) {
    throw "canonical patched HWCDC source not found: $canonicalHwcdcPath"
  }
  if (-not (Test-Path -LiteralPath $canonicalHwcdcHeaderPath -PathType Leaf)) {
    throw "canonical patched HWCDC header not found: $canonicalHwcdcHeaderPath"
  }
  if (-not (Test-Path -LiteralPath $canonicalDiagnosticHeaderPath -PathType Leaf)) {
    throw "canonical diagnostic header not found: $canonicalDiagnosticHeaderPath"
  }
  $canonicalHwcdcSha256 =
      (Get-FileHash -LiteralPath $canonicalHwcdcPath -Algorithm SHA256).Hash
  $canonicalHwcdcHeaderSha256 =
      (Get-FileHash -LiteralPath $canonicalHwcdcHeaderPath -Algorithm SHA256).Hash
  $canonicalDiagnosticHeaderSha256 =
      (Get-FileHash -LiteralPath $canonicalDiagnosticHeaderPath `
        -Algorithm SHA256).Hash
  $canonicalExact =
      $hwcdcSha256 -ceq $canonicalHwcdcSha256 -and
      $hwcdcHeaderSha256 -ceq $canonicalHwcdcHeaderSha256 -and
      $diagnosticHeaderSha256 -ceq $canonicalDiagnosticHeaderSha256
  $checks.Add([pscustomobject][ordered]@{
      name='installed_core_matches_canonical_patch';valid=$canonicalExact
      installed_cpp_sha256=$hwcdcSha256
      canonical_cpp_sha256=$canonicalHwcdcSha256
      installed_header_sha256=$hwcdcHeaderSha256
      canonical_header_sha256=$canonicalHwcdcHeaderSha256
      installed_diagnostic_header_sha256=$diagnosticHeaderSha256
      canonical_diagnostic_header_sha256=$canonicalDiagnosticHeaderSha256
    })
  if (-not $canonicalExact) {
    Add-Failure ('installed HWCDC.cpp/HWCDC.h/HWCDCR19Diagnostic.h do not ' +
      'match the canonical patch')
  }

  $requiredPatterns = [ordered]@{
    tx_state_spinlock =
      'static\s+portMUX_TYPE\s+hw_cdc_tx_mux\s*=\s*portMUX_INITIALIZER_UNLOCKED'
    partial_fifo_stash =
      'static\s+(?:volatile\s+)?size_t\s+tx_stash_len\s*=\s*0'
    atomic_tx_interrupt_helper =
      'static\s+inline\s+void\s+hw_cdc_enable_tx_intr\s*\('
    partial_fifo_write_accounting =
      'sent_size\s*=\s*usb_serial_jtag_ll_write_txfifo\s*\('
    post_disable_pending_recheck =
      'if\s*\(\s*bytes_waiting\s*\|\|\s*tx_stash_len\s*\)'
  }
  foreach ($entry in $requiredPatterns.GetEnumerator()) {
    $valid = $hwcdcText -match [string]$entry.Value
    $checks.Add([pscustomobject][ordered]@{
        name=[string]$entry.Key;pattern=[string]$entry.Value;valid=$valid
      })
    if (-not $valid) { Add-Failure "installed HWCDC lacks $($entry.Key)" }
  }

  $connectedBody = Get-FunctionBody $hwcdcText `
      'bool\s+HWCDC::isCDC_Connected\s*\(\s*\)'
  $connectedRearms = ($null -ne $connectedBody -and
      $connectedBody -match 'hw_cdc_enable_tx_intr\s*\(\s*\)' -and
      $connectedBody -notmatch 'static\s+bool\s+running')
  $checks.Add([pscustomobject][ordered]@{
      name='connection_path_always_rearms';valid=$connectedRearms
    })
  if (-not $connectedRearms) {
    Add-Failure 'HWCDC connection recovery still has a one-shot rearm gate'
  }

  $writeBody = Get-FunctionBody $hwcdcText `
      'size_t\s+HWCDC::write\s*\(\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*size_t\s+size\s*\)'
  $queuedWhileDisconnectedRearms = ($null -ne $writeBody -and
      $writeBody -match
        'if\s*\(\s*!\s*isCDC_Connected\s*\(\s*\)\s*\)[\s\S]*' +
        'flushTXBuffer\s*\(\s*buffer\s*,\s*size\s*\)[\s\S]*' +
        'hw_cdc_enable_tx_intr\s*\(\s*\)')
  $checks.Add([pscustomobject][ordered]@{
      name='disconnected_queue_rearms_tx_interrupt'
      valid=$queuedWhileDisconnectedRearms
    })
  if (-not $queuedWhileDisconnectedRearms) {
    Add-Failure 'HWCDC disconnected-write path does not rearm TX interrupt'
  }

  $replacementBody = Get-FunctionBody $hwcdcText `
      'static\s+size_t\s+flushTXBuffer\s*\(\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*size_t\s+size\s*\)'
  $replacementReportsActual =
      $null -ne $replacementBody -and
      $replacementBody -match 'original_size' -and
      $replacementBody -match 'tx_loss_epoch' -and
      $replacementBody -match 'return\s+size\s*;' -and
      $writeBody -match 'size\s*=\s*flushTXBuffer\s*\(\s*buffer\s*,\s*size\s*\)' -and
      $writeBody -match
        'size\s*=\s*so_far\s*\+\s*flushTXBuffer\s*\(\s*buffer\s*\+\s*so_far\s*,\s*to_send\s*\)'
  $checks.Add([pscustomobject][ordered]@{
      name='replacement_write_reports_actual_bytes';valid=$replacementReportsActual
    })
  if (-not $replacementReportsActual) {
    Add-Failure ('HWCDC disconnected/FIFO-replacement write does not report ' +
        'the actual retained byte count and loss epoch')
  }

  $hasCheckedWriteDeclaration = $hwcdcHeaderText -match
      'size_t\s+writeTxChecked\s*\(\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*' +
      'size_t\s+size\s*,\s*uint32_t\s+expected_loss_epoch\s*\)'
  $checkedWriteBody = Get-FunctionBody $hwcdcText `
      'size_t\s+HWCDC::writeTxChecked\s*\(\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*size_t\s+size\s*,\s*uint32_t\s+expected_loss_epoch\s*\)'
  $checkedWriteValid =
      $hasCheckedWriteDeclaration -and $null -ne $checkedWriteBody -and
      $checkedWriteBody -match 'USB_SERIAL_JTAG_INTR_BUS_RESET' -and
      $checkedWriteBody -match 'tx_loss_epoch\s*==\s*expected_loss_epoch' -and
      $checkedWriteBody -match 'xRingbufferSend' -and
      $checkedWriteBody -match 'hw_cdc_discard_tx_from_task_locked' -and
      $checkedWriteBody -match 'usb_serial_jtag_ll_ena_intr_mask' -and
      $checkedWriteBody -match 'return\s+accepted\s*;'
  $checks.Add([pscustomobject][ordered]@{
      name='epoch_checked_write_linearization';valid=$checkedWriteValid
    })
  if (-not $checkedWriteValid) {
    Add-Failure ('HWCDC lacks an epoch/reset-checked product write with ' +
        'post-enqueue quarantine before TX interrupt enable')
  }

  $checkedWriteBoundMatch = if ($null -ne $checkedWriteBody) {
    [regex]::Match(
        $checkedWriteBody,
        'if\s*\(\s*size\s*>\s*32U?\s*\)\s*\{\s*return\s+0\s*;')
  } else { $null }
  $checkedWriteRingSendPosition = if ($null -ne $checkedWriteBody) {
    $checkedWriteBody.IndexOf('xRingbufferSend')
  } else { -1 }
  $checkedWriteBoundedToProductChunk =
      $null -ne $checkedWriteBoundMatch -and
      $checkedWriteBoundMatch.Success -and
      $checkedWriteBoundMatch.Index -lt $checkedWriteRingSendPosition
  $checks.Add([pscustomobject][ordered]@{
      name='checked_write_rejects_over_32_byte_chunk'
      valid=$checkedWriteBoundedToProductChunk
    })
  if (-not $checkedWriteBoundedToProductChunk) {
    Add-Failure ('writeTxChecked does not enforce the <=32-byte hardware ' +
        'publication chunk assumed by the post-write BUS_RESET proof')
  }

  # R19 must not rely on a new IN_EMPTY edge after the endpoint has become
  # clean-idle.  On that exact boundary writeTxChecked() owns a bounded
  # task-side prime: mask/clear the stale edge, enqueue and remove the same
  # <=32-byte item, write it to FIFO, re-sample BUS_RESET, bind the payload
  # generation, publish WR_DONE, and only then re-enable IN_EMPTY.  A zero or
  # partial LL write remains in the software stash.  In particular, a queued
  # SoftwarePending item may never be replaced by a ZLP.
  $checkedWriteCode = Remove-CppComments $checkedWriteBody
  $checkedPrimeMacroScoped =
      $null -ne $checkedWriteCode -and
      $checkedWriteCode -match
        ('#if\s+defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' +
         '\s*&&\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS')
  $checkedPrimeCleanBoundary =
      $null -ne $checkedWriteCode -and
      $checkedWriteCode -match
        'vRingbufferGetInfo\s*\([\s\S]*?bytes_waiting\s*==\s*0U?' -and
      $checkedWriteCode -match 'tx_stash_len\s*==\s*0U?' -and
      $checkedWriteCode -match '!\s*tx_payload_in_flight' -and
      $checkedWriteCode -match
        'tx_payload_pickup_generation\s*==\s*tx_payload_publish_generation' -and
      $checkedWriteCode -match
        'usb_serial_jtag_ll_txfifo_writable\s*\(\s*\)\s*==\s*1'
  $checkedPrimeDisablePosition = if ($null -ne $checkedWriteCode) {
      $checkedWriteCode.IndexOf('usb_serial_jtag_ll_disable_intr_mask')
    } else { -1 }
  $checkedPrimeClearPosition = if ($checkedPrimeDisablePosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'usb_serial_jtag_ll_clr_intsts_mask', $checkedPrimeDisablePosition)
    } else { -1 }
  $checkedPrimeRingSendPosition = if ($checkedPrimeClearPosition -ge 0) {
      $checkedWriteCode.IndexOf('xRingbufferSend', $checkedPrimeClearPosition)
    } else { -1 }
  $checkedPrimeRingReceivePosition = if ($checkedPrimeRingSendPosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'xRingbufferReceiveUpTo', $checkedPrimeRingSendPosition)
    } else { -1 }
  $checkedPrimeFifoWritePosition = if ($checkedPrimeRingReceivePosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'usb_serial_jtag_ll_write_txfifo', $checkedPrimeRingReceivePosition)
    } else { -1 }
  $checkedPrimePostResetPosition = if ($checkedPrimeFifoWritePosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'reset_pending_after_fifo_write', $checkedPrimeFifoWritePosition)
    } else { -1 }
  $checkedPrimeGenerationPosition = if ($checkedPrimePostResetPosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'tx_payload_publish_generation =', $checkedPrimePostResetPosition)
    } else { -1 }
  $checkedPrimeInFlightPosition = if ($checkedPrimePostResetPosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'tx_payload_in_flight = true', $checkedPrimePostResetPosition)
    } else { -1 }
  $checkedPrimeWrDonePosition = if ($checkedPrimePostResetPosition -ge 0) {
      $checkedWriteCode.IndexOf('record_wr_done', $checkedPrimePostResetPosition)
    } else { -1 }
  $checkedPrimeHardwarePublishPosition = if ($checkedPrimeWrDonePosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'usb_serial_jtag_ll_txfifo_flush', $checkedPrimeWrDonePosition)
    } else { -1 }
  $checkedPrimeEnablePosition = if ($checkedPrimeHardwarePublishPosition -ge 0) {
      $checkedWriteCode.IndexOf(
        'usb_serial_jtag_ll_ena_intr_mask', $checkedPrimeHardwarePublishPosition)
    } else { -1 }
  $checkedPrimeOrdered =
      $checkedPrimeDisablePosition -ge 0 -and
      $checkedPrimeClearPosition -gt $checkedPrimeDisablePosition -and
      $checkedPrimeRingSendPosition -gt $checkedPrimeClearPosition -and
      $checkedPrimeRingReceivePosition -gt $checkedPrimeRingSendPosition -and
      $checkedPrimeFifoWritePosition -gt $checkedPrimeRingReceivePosition -and
      $checkedPrimePostResetPosition -gt $checkedPrimeFifoWritePosition -and
      $checkedPrimeGenerationPosition -gt $checkedPrimePostResetPosition -and
      $checkedPrimeInFlightPosition -gt $checkedPrimePostResetPosition -and
      $checkedPrimeWrDonePosition -gt $checkedPrimeGenerationPosition -and
      $checkedPrimeWrDonePosition -gt $checkedPrimeInFlightPosition -and
      $checkedPrimeHardwarePublishPosition -gt $checkedPrimeWrDonePosition -and
      $checkedPrimeEnablePosition -gt $checkedPrimeHardwarePublishPosition
  $checkedPrimeBoundedAndStashed =
      $null -ne $checkedWriteCode -and
      $checkedWriteCode -match
        'xRingbufferReceiveUpTo\s*\([\s\S]*?,\s*32U?\s*\)' -and
      $checkedWriteCode -match
        ('if\s*\(\s*sent_size\s*<\s*queued_size\s*\)' +
         '[\s\S]*?tx_stash_len\s*=\s*queued_size\s*-\s*sent_size' +
         '[\s\S]*?memmove\s*\(\s*tx_stash_buf\s*,\s*' +
         'queued_buff\s*\+\s*sent_size\s*,\s*tx_stash_len\s*\)') -and
      $checkedWriteCode -match
        'if\s*\(\s*sent_size\s*>\s*0U?\s*\)[\s\S]*?record_wr_done'
  $checkedPrimeNoSoftwarePendingZlp =
      $null -ne $checkedWriteCode -and
      $checkedWriteCode -notmatch
        'hw_cdc_r19_issue_terminal_zlp_locked\s*\(' -and
      $checkedWriteCode -notmatch
        'record_zlp_wr_done\s*\('
  $checkedWriteCleanIdlePrime =
      $checkedPrimeMacroScoped -and $checkedPrimeCleanBoundary -and
      $checkedPrimeOrdered -and $checkedPrimeBoundedAndStashed -and
      $checkedPrimeNoSoftwarePendingZlp
  $checks.Add([pscustomobject][ordered]@{
      name='r19_checked_write_clean_idle_task_primes_payload'
      expected=('macro-on clean-idle exact ring boundary masks/clears stale ' +
        'IN_EMPTY, task-primes <=32 bytes, postchecks BUS_RESET, binds the ' +
        'generation/in-flight witness, publishes WR_DONE, then enables; ' +
        'zero/partial bytes remain stashed and SoftwarePending emits no ZLP')
      valid=$checkedWriteCleanIdlePrime
      macro_scoped=$checkedPrimeMacroScoped
      clean_boundary=$checkedPrimeCleanBoundary
      ordered_publication=$checkedPrimeOrdered
      bounded_and_stashed=$checkedPrimeBoundedAndStashed
      no_software_pending_zlp=$checkedPrimeNoSoftwarePendingZlp
    })
  if (-not $checkedWriteCleanIdlePrime) {
    Add-Failure ('R19 writeTxChecked lacks the reset-safe clean-idle ' +
        'task-side payload prime, does not preserve zero/partial bytes in ' +
        'stash, or can emit a ZLP while SoftwarePending')
  }

  $isrBody = Get-FunctionBody $hwcdcText `
      'static\s+void\s+hw_cdc_isr_handler\s*\(\s*void\s*\*\s*arg\s*\)'

  # A BUS_RESET which asserts after the ISR entry snapshot but before the
  # IN_EMPTY pickup commit must win at the exact pickup linearization point.
  # Re-sample it while holding hw_cdc_tx_mux, leave IN_EMPTY untouched in
  # that branch, and let the reset-discard callback account the raw bit once.
  $inEmptyBlock = Get-FunctionBody $isrBody `
      'if\s*\(\s*usbjtag_intr_status\s*&\s*USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)'
  $inEmptyMuxEnter = if ($null -ne $inEmptyBlock) {
      $inEmptyBlock.IndexOf('portENTER_CRITICAL_ISR(&hw_cdc_tx_mux)')
    } else { -1 }
  $inEmptyResetSample = if ($inEmptyMuxEnter -ge 0) {
      $inEmptyBlock.IndexOf(
        'reset_pending_before_in_empty_pickup', $inEmptyMuxEnter)
    } else { -1 }
  $inEmptyLiveSample = if ($inEmptyMuxEnter -ge 0) {
      $inEmptyBlock.IndexOf(
        'live_interrupt_status = usb_serial_jtag_ll_get_intsts_mask()',
        $inEmptyMuxEnter)
    } else { -1 }
  $inEmptyNoResetGuard = if ($inEmptyResetSample -ge 0) {
      $inEmptyBlock.IndexOf(
        'if (!reset_pending_before_in_empty_pickup && live_in_empty_pending)',
        $inEmptyResetSample)
    } else { -1 }
  $inEmptyRecord = if ($inEmptyNoResetGuard -ge 0) {
      $inEmptyBlock.IndexOf('record_in_empty', $inEmptyNoResetGuard)
    } else { -1 }
  $inEmptyMuxExit = if ($inEmptyRecord -ge 0) {
      $inEmptyBlock.IndexOf(
        'portEXIT_CRITICAL_ISR(&hw_cdc_tx_mux)', $inEmptyRecord)
    } else { -1 }
  $latePickupResetGuard = if ($inEmptyMuxExit -ge 0) {
      $inEmptyBlock.IndexOf(
        'if (reset_pending_before_in_empty_pickup)', $inEmptyMuxExit)
    } else { -1 }
  $latePickupResetDiscard = if ($latePickupResetGuard -ge 0) {
      $inEmptyBlock.IndexOf(
        'hw_cdc_discard_tx_from_isr', $latePickupResetGuard)
    } else { -1 }
  $latePickupResetSnapshotZero = if ($latePickupResetGuard -ge 0) {
      $inEmptyBlock.IndexOf(
        'usbjtag_intr_status = 0', $latePickupResetGuard)
    } else { -1 }
  $inEmptyDrain = if ($inEmptyMuxExit -ge 0) {
      $inEmptyBlock.IndexOf('else if (in_empty_allowed', $inEmptyMuxExit)
    } else { -1 }
  $pickupResetResampledUnderMux =
      $inEmptyMuxEnter -ge 0 -and
      $inEmptyLiveSample -gt $inEmptyMuxEnter -and
      $inEmptyResetSample -gt $inEmptyMuxEnter -and
      $inEmptyNoResetGuard -gt $inEmptyResetSample -and
      $inEmptyBlock.Substring(
        $inEmptyMuxEnter, $inEmptyNoResetGuard - $inEmptyMuxEnter) -match
          'live_interrupt_status\s*=\s*' +
          'usb_serial_jtag_ll_get_intsts_mask\s*\(\s*\)' -and
      $inEmptyBlock.Substring(
        $inEmptyMuxEnter, $inEmptyNoResetGuard - $inEmptyMuxEnter) -match
          'live_interrupt_status\s*&\s*USB_SERIAL_JTAG_INTR_BUS_RESET' -and
      $inEmptyNoResetGuard -gt $inEmptyResetSample -and
      $inEmptyRecord -gt $inEmptyNoResetGuard -and
      $inEmptyMuxExit -gt $inEmptyRecord
  $checks.Add([pscustomobject][ordered]@{
      name='in_empty_pickup_rechecks_bus_reset_under_mux'
      valid=$pickupResetResampledUnderMux
    })
  if (-not $pickupResetResampledUnderMux) {
    Add-Failure ('IN_EMPTY payload pickup does not re-sample BUS_RESET under ' +
        'hw_cdc_tx_mux before record_in_empty can commit')
  }

  $pickupResetRoutesToRawOnlyDiscard =
      $latePickupResetGuard -gt $inEmptyMuxExit -and
      $latePickupResetDiscard -gt $latePickupResetGuard -and
      $latePickupResetSnapshotZero -gt $latePickupResetDiscard -and
      $inEmptyDrain -gt $latePickupResetSnapshotZero -and
      $inEmptyBlock.Substring(
        $latePickupResetGuard,
        $inEmptyDrain - $latePickupResetGuard) -match
          'hw_cdc_discard_tx_from_isr\s*\(\s*&xTaskWoken\s*,\s*false\s*\)' 
  $checks.Add([pscustomobject][ordered]@{
      name='late_pickup_reset_uses_raw_only_reset_discard'
      valid=$pickupResetRoutesToRawOnlyDiscard
    })
  if (-not $pickupResetRoutesToRawOnlyDiscard) {
    Add-Failure ('A BUS_RESET discovered at the IN_EMPTY pickup boundary is ' +
        'not routed to clean reset discard before any payload pickup/drain')
  }

  $resetDiscardBody = Get-FunctionBody $hwcdcText `
      ('static\s+void\s+hw_cdc_discard_tx_from_isr\s*\(' +
       '\s*BaseType_t\s*\*\s*\w+' +
       '(?:\s*,\s*(?:bool|\w+(?:::\w+)*)\s+\w+)?\s*\)')
  $resetPosition = if ($null -ne $isrBody) {
      $isrBody.IndexOf('USB_SERIAL_JTAG_INTR_BUS_RESET')
    } else { -1 }
  $txPosition = if ($null -ne $isrBody) {
      $isrBody.IndexOf('USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY')
    } else { -1 }
  $resetQuarantinesAllTx =
      $null -ne $resetDiscardBody -and
      $resetDiscardBody -match
        'usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
        'USB_SERIAL_JTAG_INTR_BUS_RESET\s*\|\s*' +
        'USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)' -and
      $resetDiscardBody -match 'xRingbufferReceiveUpToFromISR' -and
      $resetDiscardBody -match 'vRingbufferReturnItemFromISR' -and
      $resetDiscardBody -match 'tx_stash_len\s*=\s*0' -and
      $resetDiscardBody -match 'tx_loss_epoch' -and
      $null -ne $isrBody -and
      $isrBody -match 'hw_cdc_discard_tx_from_isr\s*\(' -and
      $resetPosition -ge 0 -and $txPosition -ge 0 -and
      $resetPosition -lt $txPosition
  $checks.Add([pscustomobject][ordered]@{
      name='bus_reset_quarantines_ring_before_tx';valid=$resetQuarantinesAllTx
    })
  if (-not $resetQuarantinesAllTx) {
    Add-Failure ('BUS_RESET status clear, ring+stash discard, and loss epoch ' +
        'advance are not serialized before handling IN_EMPTY')
  }

  $txCriticalPosition = if ($txPosition -ge 0) {
    $isrBody.IndexOf('portENTER_CRITICAL_ISR(&hw_cdc_tx_mux)', $txPosition)
  } else { -1 }
  $preTxResetPosition = if ($txCriticalPosition -ge 0) {
    $isrBody.IndexOf('reset_pending_before_tx', $txCriticalPosition)
  } else { -1 }
  $ringReceivePosition = if ($preTxResetPosition -ge 0) {
    $isrBody.IndexOf('xRingbufferReceiveUpToFromISR', $preTxResetPosition)
  } else { -1 }
  $fifoWritePosition = if ($ringReceivePosition -ge 0) {
    $isrBody.IndexOf('usb_serial_jtag_ll_write_txfifo', $ringReceivePosition)
  } else { -1 }
  $preWriteResetReturnGuardPosition = if ($ringReceivePosition -ge 0) {
    $isrBody.IndexOf(
        'if (reset_pending_before_tx && !from_stash && queued_buff != NULL)',
        $ringReceivePosition)
  } else { -1 }
  $preWriteResetReturnCallPosition =
      if ($preWriteResetReturnGuardPosition -ge 0) {
        $isrBody.IndexOf('vRingbufferReturnItemFromISR',
                         $preWriteResetReturnGuardPosition)
      } else { -1 }
  $postWriteResetPosition = if ($fifoWritePosition -ge 0) {
    $isrBody.IndexOf('reset_pending_after_fifo_write', $fifoWritePosition)
  } else { -1 }
  $fifoFlushPosition = if ($postWriteResetPosition -ge 0) {
    $isrBody.IndexOf('usb_serial_jtag_ll_txfifo_flush',
                     $postWriteResetPosition)
  } else { -1 }
  $lateResetQuarantinePosition = if ($fifoFlushPosition -ge 0) {
    $isrBody.IndexOf('hw_cdc_discard_tx_from_isr', $fifoFlushPosition)
  } else { -1 }
  $isrResetRecheckedAroundFifoWrite =
      $txCriticalPosition -ge 0 -and
      $preTxResetPosition -gt $txCriticalPosition -and
      $ringReceivePosition -gt $preTxResetPosition -and
      $fifoWritePosition -gt $ringReceivePosition -and
      $postWriteResetPosition -gt $fifoWritePosition -and
      $fifoFlushPosition -gt $postWriteResetPosition -and
      $lateResetQuarantinePosition -gt $fifoFlushPosition
  $isrPreWriteResetReturnsOutstandingItem =
      $preWriteResetReturnGuardPosition -gt $ringReceivePosition -and
      $preWriteResetReturnCallPosition -gt
        $preWriteResetReturnGuardPosition -and
      $fifoWritePosition -gt $preWriteResetReturnCallPosition
  $isrPublishChunkBelowAutoFlush =
      $null -ne $isrBody -and
      $isrBody -match
        'xRingbufferReceiveUpToFromISR\s*\(\s*tx_ring_buf\s*,\s*&queued_size\s*,\s*32\s*\)'
  $checks.Add([pscustomobject][ordered]@{
      name='bus_reset_rechecked_around_fifo_write'
      valid=$isrResetRecheckedAroundFifoWrite
    })
  if (-not $isrResetRecheckedAroundFifoWrite) {
    Add-Failure ('IN_EMPTY ISR does not recheck BUS_RESET under the TX mux ' +
        'before and after FIFO write, before any FIFO flush')
  }
  $checks.Add([pscustomobject][ordered]@{
      name='tx_publish_chunk_below_64_byte_auto_flush'
      valid=$isrPublishChunkBelowAutoFlush
    })
  if (-not $isrPublishChunkBelowAutoFlush) {
    Add-Failure ('IN_EMPTY ISR can coalesce BYTEBUF writes into a 64-byte ' +
        'hardware auto-flush before its post-write BUS_RESET check')
  }
  $checks.Add([pscustomobject][ordered]@{
      name='prewrite_reset_returns_outstanding_bytebuf_item'
      valid=$isrPreWriteResetReturnsOutstandingItem
    })
  if (-not $isrPreWriteResetReturnsOutstandingItem) {
    Add-Failure ('A BUS_RESET sampled after BYTEBUF receive can enter reset ' +
        'quarantine without returning the outstanding ring item')
  }

  # A BUS_RESET sampled after write_txfifo() but before txfifo_flush() leaves
  # software unable to prove whether those FIFO bytes belong to the old or new
  # host session. The only safe response is a sticky FIFO quarantine which a
  # *later clean BUS_RESET* may release. These assertions deliberately inspect
  # individual function bodies and source ordering so a comment, unrelated
  # helper, or early one-time check cannot satisfy the publication contract.
  $isrCode = Get-FunctionBody $hwcdcCode `
      'static\s+void\s+hw_cdc_isr_handler\s*\(\s*void\s*\*\s*\w+\s*\)'
  $resetCauseSignature = [regex]::Match(
      $hwcdcCode,
      ('static\s+void\s+hw_cdc_discard_tx_from_isr\s*\(' +
       '\s*BaseType_t\s*\*\s*\w+\s*,\s*' +
       '(?<cause_type>bool|\w+(?:::\w+)*)\s+' +
       '(?<cause_name>\w+)\s*\)'))
  $resetDiscardCode = Get-FunctionBody $hwcdcCode `
      ('static\s+void\s+hw_cdc_discard_tx_from_isr\s*\(' +
       '\s*BaseType_t\s*\*\s*\w+\s*,\s*' +
       '(?:bool|\w+(?:::\w+)*)\s+\w+\s*\)')

  $quarantineDeclaration = [regex]::Match(
      $hwcdcCode,
      'static\s+volatile\s+bool\s+tx_fifo_quarantined\s*=\s*false\s*;')
  $lossEpochDeclaration = [regex]::Match(
      $hwcdcCode, 'static\s+volatile\s+uint32_t\s+tx_loss_epoch\s*=')
  $txMuxDeclaration = [regex]::Match(
      $hwcdcCode, 'static\s+portMUX_TYPE\s+hw_cdc_tx_mux\s*=')
  $quarantineStateAdjacent =
      $quarantineDeclaration.Success -and
      $lossEpochDeclaration.Success -and
      $txMuxDeclaration.Success -and
      $quarantineDeclaration.Index -gt $lossEpochDeclaration.Index -and
      $quarantineDeclaration.Index -lt $txMuxDeclaration.Index -and
      ($quarantineDeclaration.Index - $lossEpochDeclaration.Index) -lt 512

  $resetHelperOrdered = $false
  $resetHelperCauseDriven = $false
  if ($resetCauseSignature.Success -and $null -ne $resetDiscardCode) {
    $causeName = $resetCauseSignature.Groups['cause_name'].Value
    $orderedResetPatterns = @(
      'portENTER_CRITICAL_ISR\s*\(\s*&hw_cdc_tx_mux\s*\)',
      ('usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
       'USB_SERIAL_JTAG_INTR_BUS_RESET\s*\|\s*' +
       'USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)'),
      'usb_serial_jtag_ll_disable_intr_mask\s*\(\s*USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)',
      'tx_stash_len\s*=\s*0',
      'xRingbufferReceiveUpToFromISR',
      'vRingbufferReturnItemFromISR',
      'tx_loss_epoch\s*=\s*tx_loss_epoch\s*\+\s*1U',
      'tx_fifo_quarantined\s*=',
      'portEXIT_CRITICAL_ISR\s*\(\s*&hw_cdc_tx_mux\s*\)'
    )
    $cursor = 0
    $resetHelperOrdered = $true
    foreach ($pattern in $orderedResetPatterns) {
      $orderedMatch = [regex]::Match(
          $resetDiscardCode.Substring($cursor), $pattern)
      if (-not $orderedMatch.Success) {
        $resetHelperOrdered = $false
        break
      }
      $cursor += $orderedMatch.Index + $orderedMatch.Length
    }

    $escapedCauseName = [regex]::Escape($causeName)
    $directCauseAssignment = $resetDiscardCode -match
        ('tx_fifo_quarantined\s*=\s*[^;]*\b' +
         $escapedCauseName + '\b[^;]*;')
    $cleanOnlyClear = $resetDiscardCode -match
        ('if\s*\(\s*!\s*' + $escapedCauseName +
         '\s*\)[\s\S]{0,240}?' +
         'tx_fifo_quarantined\s*=\s*false\s*;')
    $explicitCauseBranches = $resetDiscardCode -match
        ('if\s*\([^)]*\b' + $escapedCauseName +
         '\b[^)]*\)[\s\S]{0,320}?' +
         'tx_fifo_quarantined\s*=\s*true\s*;' +
         '[\s\S]{0,320}?tx_fifo_quarantined\s*=\s*false\s*;')
    $resetHelperCauseDriven =
        $directCauseAssignment -or $cleanOnlyClear -or
        $explicitCauseBranches
  }
  $checks.Add([pscustomobject][ordered]@{
      name='protected_late_fifo_quarantine_state'
      valid=($quarantineStateAdjacent -and $resetHelperOrdered -and
             $resetHelperCauseDriven)
    })
  if (-not ($quarantineStateAdjacent -and $resetHelperOrdered -and
            $resetHelperCauseDriven)) {
    Add-Failure ('HWCDC lacks a mux-protected tx_fifo_quarantined state ' +
        'whose reset helper preserves a late-FIFO quarantine and clears it ' +
        'only for a clean reset cause')
  }

  $initialResetBlock = Get-FunctionBody $isrCode `
      'if\s*\(\s*usbjtag_intr_status\s*&\s*USB_SERIAL_JTAG_INTR_BUS_RESET\s*\)'
  $initialResetCause = Get-SecondCallArgument `
      $initialResetBlock 'hw_cdc_discard_tx_from_isr'
  $initialSnapshotZeroed =
      $null -ne $initialResetBlock -and
      $initialResetBlock -match 'usbjtag_intr_status\s*=\s*0\s*;' -and
      $initialResetBlock -notmatch 'usbjtag_intr_status\s*&='
  $entryResetIsClean = Test-CleanResetCause $initialResetCause
  $checks.Add([pscustomobject][ordered]@{
      name='entry_reset_is_clean_and_zeros_full_snapshot'
      valid=($initialSnapshotZeroed -and $entryResetIsClean)
    })
  if (-not ($initialSnapshotZeroed -and $entryResetIsClean)) {
    Add-Failure ('The ISR entry BUS_RESET must use the clean reset cause and ' +
        'zero its full local interrupt snapshot before IN_EMPTY/RX handling')
  }

  $postWriteResetBlock = Get-FunctionBody $isrCode `
      'if\s*\(\s*reset_pending_after_fifo_write\s*\)'
  $completionResetBlock = Get-FunctionBody $isrCode `
      'if\s*\(\s*reset_pending_before_tx\s*\)'
  $completionResetCause = Get-SecondCallArgument `
      $completionResetBlock 'hw_cdc_discard_tx_from_isr'
  $isSimpleCauseVariable = $completionResetCause -match '^\w+$'
  $cleanCauseInitialized = $false
  $lateCauseSet = $false
  if ($isSimpleCauseVariable -and $null -ne $isrCode) {
    $escapedResetCause = [regex]::Escape($completionResetCause)
    $causeDeclaration = [regex]::Match(
        $isrCode,
        ('(?:bool|\w+(?:::\w+)*)\s+' + $escapedResetCause +
         '\s*=\s*(?<initial>[^;]+)\s*;'))
    $isrFifoWriteIndex = $isrCode.IndexOf(
        'usb_serial_jtag_ll_write_txfifo')
    $cleanCauseInitialized =
        $causeDeclaration.Success -and
        $causeDeclaration.Index -lt $isrFifoWriteIndex -and
        (Test-CleanResetCause $causeDeclaration.Groups['initial'].Value.Trim())
    if ($null -ne $postWriteResetBlock) {
      $lateAssignment = [regex]::Match(
          $postWriteResetBlock,
          ('\b' + $escapedResetCause +
           '\s*=\s*(?<late>[^;]+)\s*;'))
      $lateCauseSet =
          $lateAssignment.Success -and
          $lateAssignment.Groups['late'].Value.Trim() -match
            '^(?:true|sent_size\s*>\s*0U?|[^;]*(?:late|post|fifo|quarant)[^;]*)$'
    }
  }
  $postWriteCauseDependsOnPositiveWrite =
      $null -ne $postWriteResetBlock -and
      $postWriteResetBlock -match
        'fifo_written_after_reset\s*=\s*sent_size\s*>\s*0U?\s*;' -and
      $postWriteResetBlock -match
        'tx_fifo_quarantined\s*=\s*fifo_written_after_reset\s*;' -and
      $postWriteResetBlock -notmatch
        'tx_fifo_quarantined\s*=\s*true\s*;'
  $postBlockMatch = if ($null -ne $isrCode) {
      [regex]::Match(
          $isrCode,
          'if\s*\(\s*reset_pending_after_fifo_write\s*\)')
    } else { $null }
  $postBlockPosition = if ($null -ne $postBlockMatch -and
      $postBlockMatch.Success) { $postBlockMatch.Index } else { -1 }
  $muxReleaseMatch = if ($postBlockPosition -ge 0) {
      [regex]::Match(
          $isrCode.Substring($postBlockPosition),
          'portEXIT_CRITICAL_ISR\s*\(\s*&hw_cdc_tx_mux\s*\)')
    } else { $null }
  $muxReleaseAfterPostBlock =
      if ($null -ne $muxReleaseMatch -and $muxReleaseMatch.Success) {
        $postBlockPosition + $muxReleaseMatch.Index
      } else { -1 }
  $lateResetLatchedBeforeUnlock =
      $postWriteCauseDependsOnPositiveWrite -and
      $cleanCauseInitialized -and $lateCauseSet -and
      $muxReleaseAfterPostBlock -gt $postBlockPosition
  $checks.Add([pscustomobject][ordered]@{
      name='postwrite_reset_quarantine_requires_positive_fifo_write'
      valid=$lateResetLatchedBeforeUnlock
    })
  if (-not $lateResetLatchedBeforeUnlock) {
    Add-Failure ('A post-write BUS_RESET does not derive both the discard ' +
        'cause and sticky FIFO quarantine from sent_size > 0 under the TX ' +
        'mux while preserving clean entry/prewrite reset causes')
  }

  # Do not parse a C preprocessor expression with `[^)]*`: diagnostic-only
  # `defined(...)` clauses legitimately add parentheses inside these guards.
  # Instead bind each relevant operation to the immediately preceding guard
  # segment and require both safety predicates in that segment.
  $isrFifoCall = if ($null -ne $isrCode) {
      $isrCode.IndexOf('sent_size = usb_serial_jtag_ll_write_txfifo')
    } else { -1 }
  $isrFifoGuard = if ($isrFifoCall -ge 0) {
      $isrCode.LastIndexOf('if (!reset_pending_before_tx', $isrFifoCall)
    } else { -1 }
  $isrFifoGuardText = if ($isrFifoGuard -ge 0) {
      $isrCode.Substring($isrFifoGuard, $isrFifoCall - $isrFifoGuard)
    } else { '' }
  $isrFifoWriteGuarded =
      $isrFifoGuard -ge 0 -and
      $isrFifoGuardText -match '!\s*reset_pending_before_tx' -and
      $isrFifoGuardText -match '!\s*tx_fifo_quarantined'

  $isrEmptyMatch = if ($null -ne $isrCode) {
      [regex]::Match(
          $isrCode,
          'else\s+if\s*\(\s*' +
          '(?<condition>!reset_pending_before_tx[\s\S]*?)\)\s*\{')
    } else { $null }
  $isrEmptyCondition = if ($null -ne $isrEmptyMatch -and
      $isrEmptyMatch.Success) {
      $isrEmptyMatch.Groups['condition'].Value
    } else { '' }
  $isrEmptyBranch = Get-FunctionBody $isrCode `
      'else\s+if\s*\(\s*!reset_pending_before_tx'
  $isrEmptyCompletionQuiescent =
      $null -ne $isrEmptyBranch -and
      $isrEmptyCondition -match '!\s*reset_pending_before_tx' -and
      $isrEmptyCondition -match '!\s*tx_fifo_quarantined' -and
      $isrEmptyBranch -match 'hw_cdc_disable_tx_intr_from_isr\s*\(' -and
      $isrEmptyBranch -match 'vRingbufferGetInfo\s*\(' -and
      $isrEmptyBranch -match
        'if\s*\(\s*bytes_waiting\s*\|\|\s*tx_stash_len\s*\)' -and
      $isrEmptyBranch -match 'hw_cdc_enable_tx_intr_from_isr\s*\(' -and
      $isrEmptyBranch -notmatch 'usb_serial_jtag_ll_txfifo_flush\s*\(' -and
      $isrEmptyBranch -notmatch 'record_zlp_wr_done\s*\('

  $isrConnectedAssignment = if ($null -ne $isrCode) {
      $isrCode.IndexOf('connected = true')
    } else { -1 }
  $isrConnectedGuard = if ($isrConnectedAssignment -ge 0) {
      $isrCode.LastIndexOf('if (!tx_fifo_quarantined',
                           $isrConnectedAssignment)
    } else { -1 }
  $isrConnectedGuardVariable = if ($isrConnectedAssignment -ge 0) {
      [regex]::Match(
          $isrCode.Substring(0, $isrConnectedAssignment),
          '(?:const\s+)?bool\s+(?<name>\w+)\s*=\s*' +
          '!\s*tx_fifo_quarantined\s*;')
    } else { $null }
  $isrConnectedVariableGuarded = $false
  if ($null -ne $isrConnectedGuardVariable -and
      $isrConnectedGuardVariable.Success) {
    $connectedGuardName =
        $isrConnectedGuardVariable.Groups['name'].Value
    $isrConnectedVariableGuarded =
        $isrCode.Substring(
            $isrConnectedGuardVariable.Index,
            $isrConnectedAssignment - $isrConnectedGuardVariable.Index) -match
          ('if\s*\(\s*' + [regex]::Escape($connectedGuardName) +
           '\s*\)\s*\{')
  }
  $isrConnectedStateGated =
      ($isrConnectedGuard -ge 0 -and
       $isrConnectedGuard -lt $isrConnectedAssignment) -or
      $isrConnectedVariableGuarded

  # An empty/ZLP IN transaction can raise SERIAL_IN_EMPTY before any
  # diagnostic payload exists.  It is a USB-bus activity witness, not proof
  # that a user-space COM reader picked up application bytes.  The diagnostic
  # cached-ready bit may therefore be established by IN_EMPTY only after a
  # non-empty FIFO publication was explicitly marked in flight.  Without this
  # witness the bridge can bypass its late-open bootstrap, start the 500-ms
  # immutable-frame deadline before capture opens, and terminal-fail at zero
  # host-visible bytes.
  $payloadWitnessDeclaration = [regex]::Match(
      $hwcdcCode,
      'static\s+volatile\s+bool\s+tx_payload_in_flight\s*=\s*false\s*;')
  $payloadWitnessGuardIndex = if ($payloadWitnessDeclaration.Success) {
      $hwcdcCode.LastIndexOf('#if', $payloadWitnessDeclaration.Index)
    } else { -1 }
  $payloadWitnessGuardEnd = if ($payloadWitnessGuardIndex -ge 0) {
      $hwcdcCode.IndexOf('#endif', $payloadWitnessGuardIndex)
    } else { -1 }
  $payloadWitnessGuardText = if ($payloadWitnessGuardIndex -ge 0) {
      $hwcdcCode.Substring(
          $payloadWitnessGuardIndex,
          $hwcdcCode.IndexOf("`n", $payloadWitnessGuardIndex) -
            $payloadWitnessGuardIndex)
    } else { '' }
  $payloadWitnessMacroScoped =
      $payloadWitnessDeclaration.Success -and
      $payloadWitnessGuardIndex -ge 0 -and
      $payloadWitnessGuardIndex -lt $payloadWitnessDeclaration.Index -and
      $payloadWitnessGuardEnd -gt $payloadWitnessDeclaration.Index -and
      $payloadWitnessGuardText -match
        '#if\s+defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' -and
      $payloadWitnessGuardText -match
        '&&\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS'

  $firstInEmptyBranchEnd = if ($null -ne $isrCode) {
      $isrCode.IndexOf(
          'if (in_empty_allowed && tx_ring_buf != NULL')
    } else { -1 }
  $firstInEmptyBranch = if ($firstInEmptyBranchEnd -gt 0) {
      $isrCode.Substring(0, $firstInEmptyBranchEnd)
    } else { '' }
  $payloadPickupPredicate = [regex]::Match(
      $firstInEmptyBranch,
      '(?:const\s+)?bool\s+\w*payload\w*\s*=\s*' +
      'tx_payload_in_flight\s*;')
  $connectedAfterPayloadPredicate =
      $payloadPickupPredicate.Success -and
      $isrConnectedAssignment -gt $payloadPickupPredicate.Index -and
      $firstInEmptyBranch.Substring(
          $payloadPickupPredicate.Index,
          $isrConnectedAssignment - $payloadPickupPredicate.Index) -match
        'if\s*\([^\)]*\w*payload\w*[^\)]*\)'
  $payloadWitnessClearedAfterPickup =
      $isrConnectedAssignment -ge 0 -and
      $firstInEmptyBranch.IndexOf(
          'tx_payload_in_flight = false', $isrConnectedAssignment) -gt
        $isrConnectedAssignment

  $fifoWriteIndex = if ($null -ne $isrCode) {
      $isrCode.IndexOf('sent_size = usb_serial_jtag_ll_write_txfifo')
    } else { -1 }
  $payloadWitnessSetIndex = if ($fifoWriteIndex -ge 0) {
      $isrCode.IndexOf('tx_payload_in_flight = true', $fifoWriteIndex)
    } else { -1 }
  $payloadGenerationSetIndex = if ($fifoWriteIndex -ge 0) {
      $isrCode.IndexOf('tx_payload_publish_generation =', $fifoWriteIndex)
    } else { -1 }
  $fifoFlushIndex = if ($fifoWriteIndex -ge 0) {
      $isrCode.IndexOf('usb_serial_jtag_ll_txfifo_flush()', $fifoWriteIndex)
    } else { -1 }
  $payloadWitnessSetBeforeNonemptyFlush =
      $fifoWriteIndex -ge 0 -and
      $payloadWitnessSetIndex -gt $fifoWriteIndex -and
      $payloadGenerationSetIndex -gt $fifoWriteIndex -and
      $payloadWitnessSetIndex -lt $fifoFlushIndex -and
      $payloadGenerationSetIndex -lt $fifoFlushIndex
  $payloadWitnessClearedOnReset =
      $isrCode -match
        '(?s)USB_SERIAL_JTAG_INTR_BUS_RESET[\s\S]{0,500}?' +
        'tx_payload_in_flight\s*=\s*false' -or
      ($null -ne $resetDiscardCode -and
       $resetDiscardCode -match 'tx_payload_in_flight\s*=\s*false')
  $payloadPickupWitnessValid =
      $payloadWitnessMacroScoped -and
      $connectedAfterPayloadPredicate -and
      $payloadWitnessClearedAfterPickup -and
      $payloadWitnessSetBeforeNonemptyFlush -and
      $payloadWitnessClearedOnReset
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_connected_requires_payload_pickup_witness'
      valid=$payloadPickupWitnessValid
      macro_scoped=$payloadWitnessMacroScoped
      connected_after_payload_predicate=$connectedAfterPayloadPredicate
      cleared_after_pickup=$payloadWitnessClearedAfterPickup
      set_before_nonempty_flush=$payloadWitnessSetBeforeNonemptyFlush
      cleared_on_reset=$payloadWitnessClearedOnReset
    })
  if (-not $payloadPickupWitnessValid) {
    Add-Failure ('Diagnostic IN_EMPTY can establish cached connected state ' +
        'without a prior non-empty payload publication/pickup witness, or ' +
        'the witness is not cleared on pickup and BUS_RESET')
  }

  # usb_serial_jtag_ll_write_txfifo() is permitted to accept zero bytes even
  # after txfifo_writable() was sampled.  That is a retry, not a payload
  # publication boundary: keep the complete ring item in the protected stash,
  # return the BYTEBUF item, re-arm IN_EMPTY, and do not advance generation,
  # issue WR_DONE, post a TX event, or otherwise claim forward progress.
  $positiveFifoPublishBody = Get-FunctionBody $isrCode `
      'if\s*\(\s*sent_size\s*>\s*0U\s*\)'
  $positiveFifoPublishMatch = [regex]::Match(
      $isrCode, 'if\s*\(\s*sent_size\s*>\s*0U\s*\)')
  $positiveFifoPublishOnly =
      $null -ne $positiveFifoPublishBody -and
      $positiveFifoPublishBody -match 'tx_payload_publish_generation' -and
      $positiveFifoPublishBody -match
        'tx_payload_in_flight\s*=\s*true' -and
      $positiveFifoPublishBody -match 'record_wr_done\s*\(' -and
      $positiveFifoPublishBody -match
        'usb_serial_jtag_ll_txfifo_flush\s*\(' -and
      $positiveFifoPublishBody -match 'wrote_anything\s*=\s*true' -and
      $positiveFifoPublishBody -notmatch 'sent_size\s*<\s*queued_size' -and
      $positiveFifoPublishBody -notmatch
        'vRingbufferReturnItemFromISR\s*\(' -and
      $positiveFifoPublishBody -notmatch
        'hw_cdc_enable_tx_intr_from_isr\s*\('
  $positiveFifoPublishPosition = if ($positiveFifoPublishMatch.Success) {
      $positiveFifoPublishMatch.Index
    } else { -1 }
  $zeroFifoRetryTail = if ($positiveFifoPublishPosition -ge 0) {
      $isrCode.Substring($positiveFifoPublishPosition)
    } else { '' }
  $stashTailPosition = $zeroFifoRetryTail.IndexOf(
      'if (sent_size < queued_size)')
  $ringReturnTailPosition = $zeroFifoRetryTail.IndexOf(
      'vRingbufferReturnItemFromISR', $stashTailPosition + 1)
  $retryRearmTailPosition = $zeroFifoRetryTail.IndexOf(
      'hw_cdc_enable_tx_intr_from_isr()', $ringReturnTailPosition + 1)
  $zeroFifoRetryKeepsRingItem =
      $stashTailPosition -ge 0 -and
      $zeroFifoRetryTail -match
        ('if\s*\(\s*sent_size\s*<\s*queued_size\s*\)\s*\{' +
         '[\s\S]*?tx_stash_len\s*=\s*queued_size\s*-\s*sent_size\s*;' +
         '[\s\S]*?memmove\s*\(\s*tx_stash_buf\s*,\s*' +
         'queued_buff\s*\+\s*sent_size\s*,\s*tx_stash_len\s*\)') -and
      $ringReturnTailPosition -gt $stashTailPosition
  $zeroFifoRetryRearms =
      $retryRearmTailPosition -gt $ringReturnTailPosition
  $zeroFifoRetryDoesNotPublish = $positiveFifoPublishOnly
  $zeroFifoRetryValid =
      $zeroFifoRetryKeepsRingItem -and $zeroFifoRetryRearms -and
      $zeroFifoRetryDoesNotPublish
  $checks.Add([pscustomobject][ordered]@{
      name='zero_fifo_write_does_not_publish_payload'
      expected=('all-build safety fix: sent_size==0 retains the complete ' +
        'queued item for retry, ' +
        'returns any ring item, re-arms IN_EMPTY, and emits no payload ' +
        'generation/WR_DONE/flush/TX progress in diagnostic or normal builds')
      valid=$zeroFifoRetryValid
      full_ring_item_stashed=$zeroFifoRetryKeepsRingItem
      in_empty_rearmed=$zeroFifoRetryRearms
      no_payload_publication=$zeroFifoRetryDoesNotPublish
    })
  if (-not $zeroFifoRetryValid) {
    Add-Failure ('A zero-byte ISR FIFO write can publish/flush payload or ' +
        'discard the selected ring item instead of retaining it for retry')
  }

  # The diagnostic/non-diagnostic #if supplies two textual `if (...) {`
  # alternatives but one shared closing brace. A plain brace counter cannot
  # slice this valid preprocessor function, so use the adjacent helper
  # signatures as stable source boundaries.
  $taskEnableStart = $hwcdcCode.IndexOf(
      'static inline void hw_cdc_enable_tx_intr(void)')
  $isrEnableStart = $hwcdcCode.IndexOf(
      'static inline void hw_cdc_enable_tx_intr_from_isr(void)')
  $disableIsrStart = $hwcdcCode.IndexOf(
      'static inline void hw_cdc_disable_tx_intr_from_isr(void)')
  $taskEnableBody = if ($taskEnableStart -ge 0 -and
      $isrEnableStart -gt $taskEnableStart) {
    $hwcdcCode.Substring(
        $taskEnableStart, $isrEnableStart - $taskEnableStart)
  } else { $null }
  $isrEnableBody = if ($isrEnableStart -ge 0 -and
      $disableIsrStart -gt $isrEnableStart) {
    $hwcdcCode.Substring(
        $isrEnableStart, $disableIsrStart - $isrEnableStart)
  } else { $null }
  $taskEnableGate = if ($null -ne $taskEnableBody) {
      $taskEnableBody.IndexOf('if (enqueue_allowed)')
    } else { -1 }
  if ($taskEnableGate -lt 0 -and $null -ne $taskEnableBody) {
    $taskEnableGate = $taskEnableBody.IndexOf('if (!tx_fifo_quarantined)')
  }
  $taskEnableOperation = if ($null -ne $taskEnableBody) {
      $taskEnableBody.IndexOf('usb_serial_jtag_ll_ena_intr_mask')
    } else { -1 }
  $taskEnableGated =
      $null -ne $taskEnableBody -and
      $taskEnableBody -match 'portENTER_CRITICAL_SAFE' -and
      $taskEnableBody -match '!\s*tx_fifo_quarantined' -and
      $taskEnableBody -match
        'usb_serial_jtag_ll_ena_intr_mask\s*\(\s*USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)' -and
      $taskEnableBody.IndexOf('tx_fifo_quarantined') -lt $taskEnableGate -and
      $taskEnableGate -lt $taskEnableOperation
  $isrEnableGate = if ($null -ne $isrEnableBody) {
      $isrEnableBody.IndexOf('if (enqueue_allowed)')
    } else { -1 }
  if ($isrEnableGate -lt 0 -and $null -ne $isrEnableBody) {
    $isrEnableGate = $isrEnableBody.IndexOf('if (!tx_fifo_quarantined)')
  }
  $isrEnableOperation = if ($null -ne $isrEnableBody) {
      $isrEnableBody.IndexOf('usb_serial_jtag_ll_ena_intr_mask')
    } else { -1 }
  $isrEnableGated =
      $null -ne $isrEnableBody -and
      $isrEnableBody -match 'portENTER_CRITICAL_ISR' -and
      $isrEnableBody -match '!\s*tx_fifo_quarantined' -and
      $isrEnableBody -match
        'usb_serial_jtag_ll_ena_intr_mask\s*\(\s*USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)' -and
      $isrEnableBody.IndexOf('tx_fifo_quarantined') -lt $isrEnableGate -and
      $isrEnableGate -lt $isrEnableOperation
  $beginCode = Get-FunctionBody $hwcdcCode `
      'void\s+HWCDC::begin\s*\(\s*unsigned\s+long\s+\w+\s*\)'
  $beginAvoidsDirectInEmptyEnable =
      $null -ne $beginCode -and
      $beginCode -notmatch
        'usb_serial_jtag_ll_ena_intr_mask\s*\([^;]*USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY' -and
      $beginCode -match 'hw_cdc_enable_tx_intr\s*\(\s*\)'
  $checks.Add([pscustomobject][ordered]@{
      name='quarantine_gates_fifo_write_and_in_empty_enable'
      valid=($isrFifoWriteGuarded -and $isrEmptyCompletionQuiescent -and
             $isrConnectedStateGated -and
             $taskEnableGated -and $isrEnableGated -and
             $beginAvoidsDirectInEmptyEnable)
      isr_fifo_write_guarded=$isrFifoWriteGuarded
      isr_empty_completion_quiescent=$isrEmptyCompletionQuiescent
      isr_connected_state_gated=$isrConnectedStateGated
      task_enable_gated=$taskEnableGated
      task_enable_gate_index=$taskEnableGate
      task_enable_operation_index=$taskEnableOperation
      isr_enable_gated=$isrEnableGated
      isr_enable_gate_index=$isrEnableGate
      isr_enable_operation_index=$isrEnableOperation
      begin_uses_guarded_helper=$beginAvoidsDirectInEmptyEnable
    })
  if (-not ($isrFifoWriteGuarded -and $isrEmptyCompletionQuiescent -and
            $isrConnectedStateGated -and
            $taskEnableGated -and $isrEnableGated -and
            $beginAvoidsDirectInEmptyEnable)) {
    Add-Failure ('tx_fifo_quarantined does not gate connected=true and every ' +
        'FIFO write/SERIAL_IN_EMPTY enable path, or the empty ISR branch ' +
        'publishes a replacement ZLP instead of quiescing after the final ' +
        'short-packet pickup')
  }

  # Discover a mux-atomic guarded FIFO flush helper without constraining its
  # spelling. Call sites must not perform an unguarded direct LL flush.
  $safeFlushHelperName = $null
  $staticHelperSignatures = [regex]::Matches(
      $hwcdcCode,
      'static\s+(?:inline\s+)?(?:bool|void)\s+(?<name>hw_cdc_\w+)\s*\(')
  foreach ($helperSignature in $staticHelperSignatures) {
    $candidateName = $helperSignature.Groups['name'].Value
    $candidateBody = Get-FunctionBody $hwcdcCode `
        ('static\s+(?:inline\s+)?(?:bool|void)\s+' +
         [regex]::Escape($candidateName) + '\s*\(')
    if ($null -eq $candidateBody) { continue }
    $enterIndex = $candidateBody.IndexOf('portENTER_CRITICAL_SAFE')
    $flagIndex = $candidateBody.IndexOf('tx_fifo_quarantined')
    $flushIndex = $candidateBody.IndexOf(
        'usb_serial_jtag_ll_txfifo_flush')
    $exitIndex = $candidateBody.IndexOf('portEXIT_CRITICAL_SAFE')
    # Require the low-level flush to live in the positive allowed branch.
    # An early `if (quarantined) return` while holding the mux would otherwise
    # strand the lock and must never count as a valid guard.
    $directPositiveGuard = $candidateBody -match
        ('if\s*\(\s*!\s*tx_fifo_quarantined\s*\)\s*\{' +
         '[\s\S]{0,1400}?usb_serial_jtag_ll_txfifo_flush')
    $allowedSnapshot = [regex]::Match(
        $candidateBody,
        '(?:const\s+)?bool\s+(?<allowed>\w+)\s*=\s*' +
        '!\s*tx_fifo_quarantined[^;]*;')
    $snapshotPositiveGuard = $false
    if ($allowedSnapshot.Success) {
      $snapshotPositiveGuard = $candidateBody -match
          ('if\s*\(\s*' +
           [regex]::Escape($allowedSnapshot.Groups['allowed'].Value) +
           '\s*\)\s*\{[\s\S]{0,1400}?' +
           'usb_serial_jtag_ll_txfifo_flush')
    }
    $preExitBody = if ($exitIndex -gt 0) {
      $candidateBody.Substring(0, $exitIndex)
    } else { $candidateBody }
    $preExitWithoutDiagnosticSampleReturn = [regex]::Replace(
        $preExitBody,
        'return\s+hw_cdc_r19_diagnostic_state_locked\s*\([^;]*\)\s*;',
        '')
    $noLockStrandingReturn =
        $preExitWithoutDiagnosticSampleReturn -notmatch '\breturn\b'
    $hasGuard =
        ($directPositiveGuard -or $snapshotPositiveGuard) -and
        $noLockStrandingReturn
    if ($enterIndex -ge 0 -and $flagIndex -gt $enterIndex -and
        $flushIndex -gt $flagIndex -and $exitIndex -gt $flushIndex -and
        $hasGuard) {
      $safeFlushHelperName = $candidateName
      break
    }
  }

  $connectedCode = Get-FunctionBody $hwcdcCode `
      'bool\s+HWCDC::isCDC_Connected\s*\(\s*\)'
  $replacementCode = Get-FunctionBody $hwcdcCode `
      'static\s+size_t\s+flushTXBuffer\s*\(\s*const\s+uint8_t\s*\*\s*\w+\s*,\s*size_t\s+\w+\s*\)'
  $debugWriteCode = Get-FunctionBody $hwcdcCode `
      'static\s+void\s+ARDUINO_ISR_ATTR\s+cdc0_write_char\s*\(\s*char\s+\w+\s*\)'
  $flushCode = Get-FunctionBody $hwcdcCode `
      'void\s+HWCDC::flush\s*\(\s*void\s*\)'
  $flushCompleteCode = Get-FunctionBody $hwcdcCode `
      'bool\s+HWCDC::flushTxComplete\s*\('
  $taskFlushCallsitesSafe = -not [string]::IsNullOrWhiteSpace(
      $safeFlushHelperName)
  if ($taskFlushCallsitesSafe) {
    $escapedFlushHelper = [regex]::Escape($safeFlushHelperName)
    foreach ($callsiteBody in @(
        $connectedCode, $replacementCode, $debugWriteCode, $flushCode,
        $flushCompleteCode)) {
      if ($null -eq $callsiteBody -or
          $callsiteBody -match 'usb_serial_jtag_ll_txfifo_flush' -or
          $callsiteBody -notmatch ('\b' + $escapedFlushHelper + '\s*\(')) {
        $taskFlushCallsitesSafe = $false
        break
      }
    }
  }

  $safeQuarantineReaderName = $null
  foreach ($helperSignature in $staticHelperSignatures) {
    $candidateName = $helperSignature.Groups['name'].Value
    $candidateBody = Get-FunctionBody $hwcdcCode `
        ('static\s+(?:inline\s+)?bool\s+' +
         [regex]::Escape($candidateName) + '\s*\(')
    if ($null -eq $candidateBody -or
        $candidateBody -match 'usb_serial_jtag_ll_txfifo_flush') {
      continue
    }
    $enterIndex = $candidateBody.IndexOf('portENTER_CRITICAL_SAFE')
    $flagIndex = $candidateBody.IndexOf('tx_fifo_quarantined')
    $exitIndex = $candidateBody.IndexOf('portEXIT_CRITICAL_SAFE')
    $firstReturnIndex = $candidateBody.IndexOf('return')
    $returnIndex = $candidateBody.LastIndexOf('return')
    if ($enterIndex -ge 0 -and $flagIndex -gt $enterIndex -and
        $exitIndex -gt $flagIndex -and
        $firstReturnIndex -gt $exitIndex -and
        $returnIndex -gt $exitIndex) {
      $safeQuarantineReaderName = $candidateName
      break
    }
  }
  $isCdcQuarantineGate = $false
  if ($null -ne $connectedCode -and
      -not [string]::IsNullOrWhiteSpace($safeQuarantineReaderName)) {
    $readerCall = [regex]::Escape($safeQuarantineReaderName) +
        '\s*\(\s*\)'
    $readerPosition = [regex]::Match($connectedCode, $readerCall).Index
    $enablePosition = $connectedCode.IndexOf('hw_cdc_enable_tx_intr')
    $connectedFastPath = [regex]::Match(
        $connectedCode,
        'if\s*\(\s*connected\s*\)\s*\{\s*return\s+true\s*;')
    $isCdcQuarantineGate =
        $connectedCode -match
          ('if\s*\(\s*' + $readerCall + '\s*\)\s*\{' +
           '[\s\S]{0,200}?connected\s*=\s*false\s*;' +
           '[\s\S]{0,120}?return\s+false\s*;') -and
        $connectedFastPath.Success -and
        $readerPosition -ge 0 -and
        $readerPosition -lt $connectedFastPath.Index -and
        ($enablePosition -lt 0 -or $readerPosition -lt $enablePosition)
  }
  $checks.Add([pscustomobject][ordered]@{
      name='quarantine_gates_all_task_fifo_flush_paths'
      valid=($taskFlushCallsitesSafe -and $isCdcQuarantineGate)
      safe_flush_helper=$safeFlushHelperName
      safe_quarantine_reader=$safeQuarantineReaderName
    })
  if (-not ($taskFlushCallsitesSafe -and $isCdcQuarantineGate)) {
    Add-Failure ('isCDC/flushTXBuffer/cdc0_write_char/flush/flushTxComplete ' +
        'can directly flush a quarantined FIFO, or isCDC can rearm it ' +
        'without a mux-protected quarantine rejection')
  }

  $checkedWriteCode = Get-FunctionBody $hwcdcCode `
      'size_t\s+HWCDC::writeTxChecked\s*\('
  $checkedRingSendIndex = if ($null -ne $checkedWriteCode) {
      $checkedWriteCode.IndexOf('xRingbufferSend')
    } else { -1 }
  $checkedDirectEnableIndex = if ($null -ne $checkedWriteCode) {
      $checkedWriteCode.IndexOf('usb_serial_jtag_ll_ena_intr_mask')
    } else { -1 }
  $checkedQuarantineReads = if ($null -ne $checkedWriteCode) {
      [regex]::Matches(
          $checkedWriteCode, '!\s*tx_fifo_quarantined')
    } else { @() }
  $checkedWriteRejectsQuarantine =
      $checkedQuarantineReads.Count -ge 2 -and
      $checkedQuarantineReads[0].Index -lt $checkedRingSendIndex -and
      $checkedQuarantineReads[$checkedQuarantineReads.Count - 1].Index -gt
        $checkedRingSendIndex -and
      ($checkedDirectEnableIndex -lt 0 -or
       $checkedQuarantineReads[$checkedQuarantineReads.Count - 1].Index -lt
         $checkedDirectEnableIndex)
  $checks.Add([pscustomobject][ordered]@{
      name='checked_write_rejects_quarantine_pre_and_post_enqueue'
      valid=$checkedWriteRejectsQuarantine
    })
  if (-not $checkedWriteRejectsQuarantine) {
    Add-Failure ('writeTxChecked does not reject tx_fifo_quarantined both ' +
        'before enqueue and at its post-enqueue linearization point')
  }

  # The read-only diagnostic capture path needs one narrowly scoped cold-start
  # escape. It may enqueue only the complete 63-byte R19A/R19F frame, only at
  # a proved-clean boundary, and only while the diagnostic build macro is on.
  # These named checks are included in the sealed contract summary so a
  # candidate cannot rely only on matching file hashes.
  $bootstrapSignature =
      'size_t\s+HWCDC::writeTxBootstrapFrameChecked\s*\(' +
      '\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*size_t\s+size\s*,\s*' +
      'uint32_t\s+expected_loss_epoch\s*\)'
  $bootstrapHeaderSignature =
      'size_t\s+writeTxBootstrapFrameChecked\s*\(' +
      '\s*const\s+uint8_t\s*\*\s*buffer\s*,\s*size_t\s+size\s*,\s*' +
      'uint32_t\s+expected_loss_epoch\s*\)\s*;'
  $diagnosticGuardPattern =
      '#if\s+defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' +
      '\s*&&\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS'
  $bootstrapBody = Get-FunctionBody $hwcdcCode $bootstrapSignature
  $bootstrapHeaderMatch = [regex]::Match(
      $hwcdcHeaderCode, $bootstrapHeaderSignature)
  $bootstrapDefinitionMatch = [regex]::Match(
      $hwcdcCode, $bootstrapSignature)
  $headerGuardIndex = if ($bootstrapHeaderMatch.Success) {
      $hwcdcHeaderCode.LastIndexOf('#if', $bootstrapHeaderMatch.Index)
    } else { -1 }
  $headerGuardEnd = if ($headerGuardIndex -ge 0) {
      $hwcdcHeaderCode.IndexOf('#endif', $headerGuardIndex)
    } else { -1 }
  $cppGuardIndex = if ($bootstrapDefinitionMatch.Success) {
      $hwcdcCode.LastIndexOf('#if', $bootstrapDefinitionMatch.Index)
    } else { -1 }
  $cppGuardEnd = if ($cppGuardIndex -ge 0) {
      $hwcdcCode.IndexOf('#endif', $cppGuardIndex)
    } else { -1 }
  $headerGuardText = if ($headerGuardIndex -ge 0) {
      $hwcdcHeaderCode.Substring(
          $headerGuardIndex,
          $hwcdcHeaderCode.IndexOf("`n", $headerGuardIndex) -
            $headerGuardIndex)
    } else { '' }
  $cppGuardText = if ($cppGuardIndex -ge 0) {
      $hwcdcCode.Substring(
          $cppGuardIndex,
          $hwcdcCode.IndexOf("`n", $cppGuardIndex) - $cppGuardIndex)
    } else { '' }
  $bootstrapMacroScoped =
      [regex]::Matches(
          $hwcdcHeaderCode, 'writeTxBootstrapFrameChecked').Count -eq 1 -and
      [regex]::Matches(
          $hwcdcCode, 'HWCDC::writeTxBootstrapFrameChecked').Count -eq 1 -and
      $headerGuardIndex -ge 0 -and
      $headerGuardIndex -lt $bootstrapHeaderMatch.Index -and
      $headerGuardEnd -gt $bootstrapHeaderMatch.Index -and
      $headerGuardText -match $diagnosticGuardPattern -and
      $cppGuardIndex -ge 0 -and
      $cppGuardIndex -lt $bootstrapDefinitionMatch.Index -and
      $cppGuardEnd -gt $bootstrapDefinitionMatch.Index -and
      $cppGuardText -match $diagnosticGuardPattern
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_api_macro_scoped'
      valid=$bootstrapMacroScoped
    })
  if (-not $bootstrapMacroScoped) {
    Add-Failure ('writeTxBootstrapFrameChecked is absent, duplicated, or ' +
        'not confined to VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS in both ' +
        'HWCDC.h and HWCDC.cpp')
  }

  $bootstrapInputGuardPosition = if ($null -ne $bootstrapBody) {
      $bootstrapBody.IndexOf('size != 63U')
    } else { -1 }
  $bootstrapLockPosition = if ($null -ne $bootstrapBody) {
      $bootstrapBody.IndexOf('xSemaphoreTake')
    } else { -1 }
  $bootstrapRingSendPosition = if ($null -ne $bootstrapBody) {
      $bootstrapBody.IndexOf('xRingbufferSend')
    } else { -1 }
  $bootstrapExactFrameOnly =
      $null -ne $bootstrapBody -and
      $bootstrapBody -match 'buffer\s*==\s*NULL' -and
      $bootstrapBody -match 'size\s*!=\s*63U?' -and
      $bootstrapBody -notmatch 'isPlugged\s*\(\s*\)' -and
      $bootstrapBody -match 'intr_handle\s*==\s*NULL' -and
      $bootstrapBody -match '!\s*connected' -and
      $bootstrapBody -notmatch 'isCDC_Connected\s*\(' -and
      $bootstrapBody -notmatch '(?m)^\s*connected\s*=' -and
      $bootstrapInputGuardPosition -ge 0 -and
      $bootstrapLockPosition -gt $bootstrapInputGuardPosition -and
      $bootstrapRingSendPosition -gt $bootstrapLockPosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_exact_63_byte_cold_start_only'
      valid=$bootstrapExactFrameOnly
    })
  if (-not $bootstrapExactFrameOnly) {
    Add-Failure ('Diagnostic bootstrap is not restricted to one exact ' +
        '63-byte, initialized-ISR cold-start frame independent of the ' +
        'fallible SOF watchdog')
  }

  $bootstrapEmptyBoundary =
      $null -ne $bootstrapBody -and
      $bootstrapBody -match 'xRingbufferGetCurFreeSize\s*\(' -and
      $bootstrapBody -match 'vRingbufferGetInfo\s*\(' -and
      $bootstrapBody -match 'bytes_waiting\s*==\s*0' -and
      $bootstrapBody -match 'tx_stash_len\s*==\s*0' -and
      $bootstrapBody -match 'free_space\s*>=\s*size' -and
      $bootstrapBody -match 'usb_serial_jtag_ll_txfifo_writable\s*\(\s*\)\s*==\s*1' -and
      $bootstrapBody -match '!\s*tx_fifo_quarantined' -and
      $bootstrapBody -match '!\s*tx_bootstrap_enqueue_fence' -and
      $bootstrapBody -match '!\s*tx_bootstrap_enqueue_aborted' -and
      $bootstrapBody -match '!\s*tx_debug_writer_active'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_requires_clean_empty_boundary'
      valid=$bootstrapEmptyBoundary
    })
  if (-not $bootstrapEmptyBoundary) {
    Add-Failure ('Diagnostic bootstrap does not prove empty ring/stash/FIFO, ' +
        'capacity, quarantine, and writer exclusion before enqueue')
  }

  $bootstrapFenceSetPosition = if ($null -ne $bootstrapBody) {
      $bootstrapBody.IndexOf('tx_bootstrap_enqueue_fence = true')
    } else { -1 }
  $bootstrapPostcheckPosition = if ($null -ne $bootstrapBody) {
      $bootstrapBody.IndexOf('const bool postcheck_valid')
    } else { -1 }
  $bootstrapDiscardPosition = if ($bootstrapPostcheckPosition -ge 0) {
      $bootstrapBody.IndexOf(
          'hw_cdc_discard_tx_from_task_locked', $bootstrapPostcheckPosition)
    } else { -1 }
  $bootstrapFenceReleasePosition = if ($bootstrapPostcheckPosition -ge 0) {
      $bootstrapBody.IndexOf(
          'tx_bootstrap_enqueue_fence = false', $bootstrapPostcheckPosition)
    } else { -1 }
  $bootstrapEnablePosition = if ($bootstrapFenceReleasePosition -ge 0) {
      $bootstrapBody.IndexOf(
          'usb_serial_jtag_ll_ena_intr_mask', $bootstrapFenceReleasePosition)
    } else { -1 }
  $bootstrapAcceptPosition = if ($bootstrapEnablePosition -ge 0) {
      $bootstrapBody.IndexOf('accepted = size', $bootstrapEnablePosition)
    } else { -1 }
  $bootstrapKickPosition = if ($bootstrapPostcheckPosition -ge 0) {
      $bootstrapBody.IndexOf(
          'usb_serial_jtag_ll_txfifo_flush()', $bootstrapPostcheckPosition)
    } else { -1 }
  $bootstrapAllOrZeroFence =
      $bootstrapFenceSetPosition -ge 0 -and
      $bootstrapRingSendPosition -gt $bootstrapFenceSetPosition -and
      $bootstrapPostcheckPosition -gt $bootstrapRingSendPosition -and
      $bootstrapDiscardPosition -gt $bootstrapPostcheckPosition -and
      $bootstrapFenceReleasePosition -gt $bootstrapPostcheckPosition -and
      $bootstrapEnablePosition -gt $bootstrapFenceReleasePosition -and
      $bootstrapKickPosition -gt $bootstrapFenceReleasePosition -and
      $bootstrapEnablePosition -gt $bootstrapKickPosition -and
      $bootstrapAcceptPosition -gt $bootstrapEnablePosition -and
      $bootstrapBody -match 'size_t\s+accepted\s*=\s*0' -and
      $bootstrapBody -match 'return\s+accepted\s*;'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_all_or_zero_publication_fence'
      valid=$bootstrapAllOrZeroFence
    })
  if (-not $bootstrapAllOrZeroFence) {
    Add-Failure ('Diagnostic bootstrap can publish before its post-enqueue ' +
        'proof, or does not roll back and report all-or-zero')
  }

  # A read-only host cannot be bootstrapped by an empty-FIFO/ZLP request
  # alone on the affected ESP32-S3 path.  After the complete immutable frame
  # is fenced in the software ring, the diagnostic-only escape must prime the
  # first bounded payload chunk into the hardware FIFO.  The task-side prime
  # remains behind the same epoch/reset/quarantine proof as the ISR and leaves
  # any unwritten suffix in the stash so the frame is never shortened.
  $bootstrapHeadReceivePosition = if ($bootstrapPostcheckPosition -ge 0) {
      $bootstrapBody.IndexOf(
          'xRingbufferReceiveUpTo', $bootstrapPostcheckPosition)
    } else { -1 }
  $bootstrapHeadWritePosition = if ($bootstrapHeadReceivePosition -ge 0) {
      $bootstrapBody.IndexOf(
          'usb_serial_jtag_ll_write_txfifo', $bootstrapHeadReceivePosition)
    } else { -1 }
  $bootstrapPostWriteResetPosition = if ($bootstrapHeadWritePosition -ge 0) {
      $bootstrapBody.IndexOf(
          'reset_pending_after_fifo_write', $bootstrapHeadWritePosition)
    } else { -1 }
  $bootstrapPickupWitnessPosition = if ($bootstrapPostWriteResetPosition -ge 0) {
      $bootstrapBody.IndexOf(
          'tx_payload_in_flight = true', $bootstrapPostWriteResetPosition)
    } else { -1 }
  $bootstrapPayloadPrimedBeforeFlush =
      $bootstrapHeadReceivePosition -gt $bootstrapPostcheckPosition -and
      $bootstrapHeadWritePosition -gt $bootstrapHeadReceivePosition -and
      $bootstrapPostWriteResetPosition -gt $bootstrapHeadWritePosition -and
      $bootstrapPickupWitnessPosition -gt $bootstrapPostWriteResetPosition -and
      $bootstrapKickPosition -gt $bootstrapPickupWitnessPosition -and
      $bootstrapBody -match
        'xRingbufferReceiveUpTo\s*\([^;]*?32U\s*\)' -and
      $bootstrapBody -match
        'sent_size\s*=\s*usb_serial_jtag_ll_write_txfifo' -and
      $bootstrapBody -match
        'sent_size\s*<\s*queued_size[\s\S]{0,360}?tx_stash_len[\s\S]{0,240}?memmove' -and
      $bootstrapBody -match
        'reset_pending_after_fifo_write[\s\S]{0,420}?tx_fifo_quarantined[\s\S]{0,520}?hw_cdc_discard_tx_from_task_locked' -and
      $bootstrapBody -match
        'sent_size\s*==\s*0U[\s\S]{0,520}?hw_cdc_discard_tx_from_task_locked'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_payload_primes_fifo_before_flush'
      valid=$bootstrapPayloadPrimedBeforeFlush
      receive_position=$bootstrapHeadReceivePosition
      fifo_write_position=$bootstrapHeadWritePosition
      post_write_reset_position=$bootstrapPostWriteResetPosition
      pickup_witness_position=$bootstrapPickupWitnessPosition
      flush_position=$bootstrapKickPosition
    })
  if (-not $bootstrapPayloadPrimedBeforeFlush) {
    Add-Failure ('Diagnostic bootstrap still relies on an empty-FIFO/ZLP ' +
        'kick instead of publishing a reset-protected payload head before ' +
        'waiting for flush completion')
  }

  # SERIAL_IN_EMPTY is asserted at reset/empty boundaries as well as after a
  # real IN pickup.  The bootstrap must clear that stale status adjacent to
  # publication, issue wr_done while the interrupt is still disabled, and
  # arm IN_EMPTY only afterwards.  Enabling before wr_done lets the stale
  # empty event consume tx_payload_in_flight and strand the ring suffix.
  $bootstrapStaleInEmptyClearPosition =
      if ($bootstrapPickupWitnessPosition -ge 0) {
        $bootstrapBody.IndexOf(
            'usb_serial_jtag_ll_clr_intsts_mask',
            $bootstrapPickupWitnessPosition)
      } else { -1 }
  $bootstrapPublishBeforeInEmptyEnable =
      $bootstrapStaleInEmptyClearPosition -gt
        $bootstrapPickupWitnessPosition -and
      $bootstrapKickPosition -gt $bootstrapStaleInEmptyClearPosition -and
      $bootstrapEnablePosition -gt $bootstrapKickPosition -and
      $bootstrapAcceptPosition -gt $bootstrapEnablePosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_publishes_before_in_empty_enable'
      valid=$bootstrapPublishBeforeInEmptyEnable
      pickup_witness_position=$bootstrapPickupWitnessPosition
      stale_in_empty_clear_position=$bootstrapStaleInEmptyClearPosition
      flush_position=$bootstrapKickPosition
      enable_position=$bootstrapEnablePosition
    })
  if (-not $bootstrapPublishBeforeInEmptyEnable) {
    Add-Failure ('Diagnostic bootstrap can arm IN_EMPTY before wr_done ' +
        'publishes payload, allowing a stale empty interrupt to consume ' +
        'the pickup witness')
  }

  $bootstrapResetEpochChecked =
      $null -ne $bootstrapBody -and
      $bootstrapBody -match 'reset_pending_before' -and
      $bootstrapBody -match 'reset_pending_after' -and
      [regex]::Matches(
          $bootstrapBody,
          'tx_loss_epoch\s*==\s*expected_loss_epoch').Count -ge 2 -and
      [regex]::Matches(
          $bootstrapBody,
          'USB_SERIAL_JTAG_INTR_BUS_RESET').Count -ge 2 -and
      $bootstrapBody -notmatch 'host_still_present' -and
      $bootstrapBody -notmatch 'isPlugged\s*\(\s*\)' -and
      $bootstrapEnablePosition -gt $bootstrapKickPosition -and
      $hwcdcCode -match '(?s)#if\s+defined\(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\).*?if\s*\(connected\)\s*\{\s*return\s+true\s*;' -and
      $hwcdcCode -match 'connected\s*\|\|\s*isPlugged\s*\(\s*\)'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_rechecks_epoch_reset_and_presence'
      valid=$bootstrapResetEpochChecked
    })
  if (-not $bootstrapResetEpochChecked) {
    Add-Failure ('Diagnostic bootstrap does not recheck loss epoch, BUS_RESET, ' +
        'and then establish an SOF-independent host-pickup path')
  }

  $isrFenceSnapshotPosition = if ($null -ne $isrCode) {
      $isrCode.IndexOf('const bool bootstrap_enqueue_fenced')
    } else { -1 }
  $isrReceiveAfterFencePosition = if ($isrFenceSnapshotPosition -ge 0) {
      $isrCode.IndexOf(
          'xRingbufferReceiveUpToFromISR', $isrFenceSnapshotPosition)
    } else { -1 }
  $isrWriteAfterFencePosition = if ($isrReceiveAfterFencePosition -ge 0) {
      $isrCode.IndexOf(
          'usb_serial_jtag_ll_write_txfifo', $isrReceiveAfterFencePosition)
    } else { -1 }
  $isrFenceNegativeReferences = if ($null -ne $isrCode) {
      [regex]::Matches($isrCode, '!\s*bootstrap_enqueue_fenced')
    } else { @() }
  $isrRespectsBootstrapFence =
      $null -ne $isrCode -and
      $isrCode -match 'in_empty_allowed[\s\S]{0,240}?!\s*tx_bootstrap_enqueue_fence' -and
      $isrCode -match 'in_empty_allowed[\s\S]{0,300}?!\s*tx_bootstrap_enqueue_aborted' -and
      $isrFenceSnapshotPosition -ge 0 -and
      $isrReceiveAfterFencePosition -gt $isrFenceSnapshotPosition -and
      $isrWriteAfterFencePosition -gt $isrReceiveAfterFencePosition -and
      $isrFenceNegativeReferences.Count -ge 2 -and
      $isrFenceNegativeReferences[0].Index -lt
        $isrReceiveAfterFencePosition -and
      $isrFenceNegativeReferences[1].Index -gt
        $isrReceiveAfterFencePosition -and
      $isrFenceNegativeReferences[1].Index -lt $isrWriteAfterFencePosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_isr_fence_before_ring_and_fifo'
      valid=$isrRespectsBootstrapFence
    })
  if (-not $isrRespectsBootstrapFence) {
    Add-Failure ('IN_EMPTY ISR can remove ring bytes or write FIFO after the ' +
        'diagnostic bootstrap publication fence is acquired')
  }

  $debugBeginBody = Get-FunctionBody $hwcdcCode `
      'static\s+inline\s+bool\s+hw_cdc_try_begin_debug_write\s*\('
  $debugEndBody = Get-FunctionBody $hwcdcCode `
      'static\s+inline\s+void\s+hw_cdc_end_debug_write\s*\('
  $debugReservationPosition = if ($null -ne $debugWriteCode) {
      $debugWriteCode.IndexOf('hw_cdc_try_begin_debug_write')
    } else { -1 }
  $debugFirstPublishPosition = if ($null -ne $debugWriteCode) {
      @(
        $debugWriteCode.IndexOf('flushTXBuffer'),
        $debugWriteCode.IndexOf('xRingbufferSendFromISR'),
        $debugWriteCode.IndexOf('xRingbufferSend(')
      ) | Where-Object { $_ -ge 0 } | Measure-Object -Minimum |
        Select-Object -ExpandProperty Minimum
    } else { -1 }
  $debugWriterSerialized =
      $null -ne $debugBeginBody -and
      $debugBeginBody -match 'portENTER_CRITICAL_SAFE\s*\(\s*&hw_cdc_tx_mux\s*\)' -and
      $debugBeginBody -match '!\s*tx_bootstrap_enqueue_fence' -and
      $debugBeginBody -match '!\s*tx_bootstrap_enqueue_aborted' -and
      $debugBeginBody -match 'tx_debug_writer_active\s*=\s*true' -and
      $null -ne $debugEndBody -and
      $debugEndBody -match 'tx_debug_writer_active\s*=\s*false' -and
      $debugReservationPosition -ge 0 -and
      $debugFirstPublishPosition -gt $debugReservationPosition -and
      [regex]::Matches(
          $debugWriteCode, 'hw_cdc_end_debug_write\s*\(').Count -ge 2 -and
      $bootstrapBody -match '!\s*tx_debug_writer_active'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bootstrap_serializes_debug_writer'
      valid=$debugWriterSerialized
    })
  if (-not $debugWriterSerialized) {
    Add-Failure ('cdc0_write_char can mix a debug byte with the diagnostic ' +
        'bootstrap frame or race the empty-boundary proof')
  }

  $flushFinalFifoIndex = if ($null -ne $flushCompleteCode) {
      $flushCompleteCode.IndexOf('const bool fifo_picked_up')
    } else { -1 }
  $flushCompletionMatch = if ($null -ne $flushCompleteCode) {
      [regex]::Match(
          $flushCompleteCode,
          '(?m)^\s*complete\s*=\s*true\s*;')
    } else { $null }
  $flushCompletionIndex =
      if ($null -ne $flushCompletionMatch -and
          $flushCompletionMatch.Success) {
        $flushCompletionMatch.Index
      } else { -1 }
  $flushQuarantineReads = if ($null -ne $flushCompleteCode) {
      [regex]::Matches(
          $flushCompleteCode, '!\s*tx_fifo_quarantined')
    } else { @() }
  $flushCompleteRejectsQuarantine =
      $flushQuarantineReads.Count -ge 2 -and
      $flushQuarantineReads[0].Index -lt $flushFinalFifoIndex -and
      $flushQuarantineReads[$flushQuarantineReads.Count - 1].Index -gt
        $flushFinalFifoIndex -and
      $flushCompletionIndex -gt
        $flushQuarantineReads[$flushQuarantineReads.Count - 1].Index
  $checks.Add([pscustomobject][ordered]@{
      name='flush_complete_rejects_quarantine_initial_and_final'
      valid=$flushCompleteRejectsQuarantine
    })
  if (-not $flushCompleteRejectsQuarantine) {
    Add-Failure ('flushTxComplete does not reject tx_fifo_quarantined in ' +
        'both its initial predicate and final completion sample')
  }

  $flushPayloadCompletionDeclaration = if ($null -ne $flushCompleteCode) {
      [regex]::Match(
          $flushCompleteCode,
          '(?:const\s+)?bool\s+payload_pickup_complete\s*=')
    } else { $null }
  $flushPayloadInFlightRead = if ($null -ne $flushCompleteCode) {
      $flushCompleteCode.IndexOf('!tx_payload_in_flight')
    } else { -1 }
  $flushPayloadCompletionAssignment = if ($null -ne $flushCompleteCode) {
      [regex]::Match(
          $flushCompleteCode,
          ('\bpayload_pickup_complete\s*=\s*' +
           '!\s*tx_payload_in_flight\s*&&\s*' +
           'tx_payload_pickup_generation\s*==\s*' +
           'tx_payload_publish_generation\s*;'))
    } else { $null }
  $flushPayloadCompletionUseMatch = if ($null -ne $flushCompleteCode) {
      [regex]::Match(
          $flushCompleteCode,
          ('if\s*\(\s*host_present\s*&&\s*epoch_matches\s*&&\s*' +
           'software_empty\s*&&\s*fifo_writable\s*&&\s*' +
           'payload_pickup_complete\s*\)'))
    } else { $null }
  $flushPayloadCompletionUse =
      if ($null -ne $flushPayloadCompletionUseMatch -and
          $flushPayloadCompletionUseMatch.Success) {
        $flushPayloadCompletionUseMatch.Index
      } else { -1 }
  $payloadPublishGenerationDeclared =
      $hwcdcCode -match
        'static\s+volatile\s+uint32_t\s+tx_payload_publish_generation\s*=\s*0\s*;'
  $payloadPickupGenerationDeclared =
      $hwcdcCode -match
        'static\s+volatile\s+uint32_t\s+tx_payload_pickup_generation\s*=\s*0\s*;'
  $payloadGenerationPublished =
      [regex]::Matches(
          $hwcdcCode,
          'tx_payload_publish_generation\s*=\s*' +
          'tx_payload_publish_generation\s*\+\s*1U\s*;').Count -ge 2
  $payloadGenerationPickedUp =
      $null -ne $isrCode -and
      $isrCode -match
        'tx_payload_pickup_generation\s*=\s*' +
        'tx_payload_publish_generation\s*;'
  $isrPayloadWritePosition = if ($null -ne $isrCode) {
      $isrCode.IndexOf(
          'usb_serial_jtag_ll_write_txfifo(queued_buff, queued_size)')
    } else { -1 }
  $isrPublishGenerationPosition = if ($isrPayloadWritePosition -ge 0) {
      $isrCode.IndexOf(
          'tx_payload_publish_generation =', $isrPayloadWritePosition)
    } else { -1 }
  $isrPayloadInFlightPosition = if ($isrPayloadWritePosition -ge 0) {
      $isrCode.IndexOf(
          'tx_payload_in_flight = true', $isrPayloadWritePosition)
    } else { -1 }
  $isrPayloadFlushPosition = if ($isrPayloadWritePosition -ge 0) {
      $isrCode.IndexOf(
          'usb_serial_jtag_ll_txfifo_flush();', $isrPayloadWritePosition)
    } else { -1 }
  $isrGenerationArmedBeforePublish =
      $isrPublishGenerationPosition -gt $isrPayloadWritePosition -and
      $isrPayloadInFlightPosition -gt $isrPayloadWritePosition -and
      $isrPublishGenerationPosition -lt $isrPayloadFlushPosition -and
      $isrPayloadInFlightPosition -lt $isrPayloadFlushPosition
  $flushPayloadGenerationEqual =
      $null -ne $flushCompleteCode -and
      $flushCompleteCode -match
        'tx_payload_pickup_generation\s*==\s*' +
        'tx_payload_publish_generation'
  $flushRequiresPickupCompletion =
      $null -ne $flushPayloadCompletionDeclaration -and
      $flushPayloadCompletionDeclaration.Success -and
      $null -ne $flushPayloadCompletionAssignment -and
      $flushPayloadCompletionAssignment.Success -and
      $flushPayloadCompletionAssignment.Index -gt
        $flushPayloadCompletionDeclaration.Index -and
      $flushPayloadInFlightRead -gt
        $flushPayloadCompletionAssignment.Index -and
      $flushPayloadCompletionUse -gt $flushPayloadInFlightRead -and
      $flushCompletionIndex -gt $flushPayloadCompletionUse -and
      $payloadPublishGenerationDeclared -and
      $payloadPickupGenerationDeclared -and
      $payloadGenerationPublished -and
      $payloadGenerationPickedUp -and
      $isrGenerationArmedBeforePublish -and
      $flushPayloadGenerationEqual
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_flush_requires_payload_pickup_completion'
      valid=$flushRequiresPickupCompletion
      declaration_position=if ($null -ne $flushPayloadCompletionDeclaration -and
          $flushPayloadCompletionDeclaration.Success) {
        $flushPayloadCompletionDeclaration.Index
      } else { -1 }
      in_flight_read_position=$flushPayloadInFlightRead
      assignment_position=if ($null -ne $flushPayloadCompletionAssignment -and
          $flushPayloadCompletionAssignment.Success) {
        $flushPayloadCompletionAssignment.Index
      } else { -1 }
      success_gate_position=$flushPayloadCompletionUse
      completion_position=$flushCompletionIndex
      publish_generation_declared=$payloadPublishGenerationDeclared
      pickup_generation_declared=$payloadPickupGenerationDeclared
      generation_published=$payloadGenerationPublished
      generation_picked_up=$payloadGenerationPickedUp
      isr_generation_armed_before_publish=$isrGenerationArmedBeforePublish
      flush_generation_equal=$flushPayloadGenerationEqual
    })
  if (-not $flushRequiresPickupCompletion) {
    Add-Failure ('flushTxComplete can report success while a diagnostic ' +
        'payload is still awaiting its IN_EMPTY pickup witness')
  }

  # The current R19 path publishes at most 32 bytes into a 64-byte endpoint.
  # Its final publication is therefore already a USB short packet: after the
  # matching generation is picked up, a terminal ZLP is neither needed nor
  # allowed to become a new completion dependency.  Keep the persistent-ZLP
  # implementation available for a future full/unknown packet policy, while
  # explicitly recording this short-packet success with `false`.
  $endpointPacketConstant = [regex]::Match(
      $hwcdcCode,
      ('static\s+constexpr\s+size_t\s+' +
       '(?<name>\w*(?:usb_)?endpoint\w*(?:packet|bytes|size)\w*)\s*=\s*64U?\s*;'))
  $maxPublicationConstant = [regex]::Match(
      $hwcdcCode,
      ('static\s+constexpr\s+size_t\s+' +
       '(?<name>\w*(?:max|maximum)\w*(?:payload|publication)\w*)\s*=\s*32U?\s*;'))
  $publicationBoundAsserted = $false
  if ($endpointPacketConstant.Success -and $maxPublicationConstant.Success) {
    $endpointName = [regex]::Escape(
        $endpointPacketConstant.Groups['name'].Value)
    $publicationName = [regex]::Escape(
        $maxPublicationConstant.Groups['name'].Value)
    $publicationBoundAsserted = $hwcdcCode -match
        ('static_assert\s*\(\s*' + $publicationName + '\s*<\s*' +
         $endpointName)
  }
  $isrPublicationBounded =
      $null -ne $isrCode -and
      $isrCode -match
        ('xRingbufferReceiveUpToFromISR\s*\([\s\S]*?,\s*' +
         '(?:32U?|\w*(?:max|maximum)\w*(?:payload|publication)\w*)\s*\)')
  $bootstrapPublicationBounded =
      $null -ne $bootstrapBody -and
      $bootstrapBody -match
        ('xRingbufferReceiveUpTo\s*\([\s\S]*?,\s*' +
         '(?:32U?|\w*(?:max|maximum)\w*(?:payload|publication)\w*)\s*\)')
  $checkedPublicationBounded =
      $null -ne $checkedWriteCode -and
      $checkedWriteCode -match
        ('xRingbufferReceiveUpTo\s*\([\s\S]*?,\s*' +
         '(?:32U?|\w*(?:max|maximum)\w*(?:payload|publication)\w*)\s*\)')
  $allR19PayloadPublicationsAreShort =
      $endpointPacketConstant.Success -and
      $maxPublicationConstant.Success -and
      $publicationBoundAsserted -and
      $checkedWriteBoundedToProductChunk -and
      $isrPublicationBounded -and $bootstrapPublicationBounded -and
      $checkedPublicationBounded
  $checks.Add([pscustomobject][ordered]@{
      name='r19_all_payload_publications_are_explicit_usb_short_packets'
      expected=('macro-on maximum payload publication is explicitly 32 bytes, ' +
        'statically below the 64-byte USB endpoint, at ISR/bootstrap/checked ' +
        'task-prime sites')
      valid=$allR19PayloadPublicationsAreShort
      endpoint_constant=$endpointPacketConstant.Success
      publication_constant=$maxPublicationConstant.Success
      static_bound=$publicationBoundAsserted
      isr_bounded=$isrPublicationBounded
      bootstrap_bounded=$bootstrapPublicationBounded
      checked_write_bounded=$checkedPublicationBounded
    })
  if (-not $allR19PayloadPublicationsAreShort) {
    Add-Failure ('R19 does not explicitly prove that every ISR/bootstrap/' +
        'checked task-side payload publication is <=32 bytes and therefore ' +
        'strictly shorter than the 64-byte USB endpoint')
  }

  $flushShortPacketCode = Remove-CppComments $flushCompleteCode
  $shortPolicyDeclaration =
      $null -ne $flushShortPacketCode -and
      $flushShortPacketCode -match
        '(?:const\s+)?bool\s+terminal_zlp_required\s*=\s*false\s*;'
  $terminalPolicyGuard =
      $null -ne $flushShortPacketCode -and
      $flushShortPacketCode -match
        ('if\s*\(\s*terminal_zlp_required\s*\)\s*\{' +
         '[\s\S]*?hw_cdc_r19_issue_terminal_zlp_locked\s*\(') -and
      $flushShortPacketCode -match
        ('terminal_zlp_picked_up\s*=\s*!\s*terminal_zlp_required\s*\|\|' +
         '[\s\S]*?HwCdcR19TerminalZlpState::PickedUp')
  $shortSuccessRecordsPolicy =
      $null -ne $flushShortPacketCode -and
      $flushShortPacketCode -match
        ('record_flush_success\s*\(\s*' +
         'hw_cdc_r19_diagnostic_state_locked\s*\(\s*\)\s*,\s*false\s*\)')
  $softwareEmptyGatePosition = if ($null -ne $flushShortPacketCode) {
      $flushShortPacketCode.IndexOf(
        'if (host_present && epoch_matches && software_empty && fifo_writable')
    } else { -1 }
  $terminalIssuePosition = if ($softwareEmptyGatePosition -ge 0) {
      $flushShortPacketCode.IndexOf(
        'hw_cdc_r19_issue_terminal_zlp_locked', $softwareEmptyGatePosition)
    } else { -1 }
  $noZlpWhileSoftwarePending =
      $softwareEmptyGatePosition -ge 0 -and
      $terminalIssuePosition -gt $softwareEmptyGatePosition -and
      $checkedPrimeNoSoftwarePendingZlp
  $shortPacketFlushCompletesWithoutZlp =
      $allR19PayloadPublicationsAreShort -and
      $shortPolicyDeclaration -and $terminalPolicyGuard -and
      $shortSuccessRecordsPolicy -and $flushRequiresPickupCompletion -and
      $noZlpWhileSoftwarePending
  $checks.Add([pscustomobject][ordered]@{
      name='r19_short_packet_flush_skips_terminal_zlp'
      expected=('after matching payload pickup, current <=32-byte R19 ' +
        'publications complete without terminal ZLP and call ' +
        'record_flush_success(state, false); full/unknown compatibility is ' +
        'kept behind terminal_zlp_required; SoftwarePending emits no ZLP')
      valid=$shortPacketFlushCompletesWithoutZlp
      short_policy_declared=$shortPolicyDeclaration
      terminal_policy_guarded=$terminalPolicyGuard
      records_false_policy=$shortSuccessRecordsPolicy
      matching_pickup_required=$flushRequiresPickupCompletion
      no_zlp_while_software_pending=$noZlpWhileSoftwarePending
    })
  if (-not $shortPacketFlushCompletesWithoutZlp) {
    Add-Failure ('R19 short-packet flush still issues/waits for a terminal ZLP, ' +
        'does not record record_flush_success(..., false), or can issue ZLP ' +
        'while software payload remains pending')
  }

  $endCode = Get-FunctionBody $hwcdcCode `
      'void\s+HWCDC::end\s*\(\s*\)'
  $setTxBufferCode = Get-FunctionBody $hwcdcCode `
      'size_t\s+HWCDC::setTxBufferSize\s*\('
  $clearStashCode = Get-FunctionBody $hwcdcCode `
      'static\s+inline\s+void\s+hw_cdc_clear_tx_stash\s*\('
  $ordinaryWriteCode = Get-FunctionBody $hwcdcCode `
      'size_t\s+HWCDC::write\s*\(\s*const\s+uint8_t'
  $falseAssignments = [regex]::Matches(
      $hwcdcCode,
      '\btx_fifo_quarantined\s*=\s*false\s*;')
  $resetHelperHasRuntimeClear =
      $null -ne $resetDiscardCode -and
      $resetDiscardCode -match
        '\btx_fifo_quarantined\s*=\s*false\s*;'
  $falseAssignmentsResetOwned =
      $quarantineDeclaration.Success -and
      ($falseAssignments.Count -eq 1 -or
       ($falseAssignments.Count -eq 2 -and
        $resetHelperHasRuntimeClear))
  $forbiddenClearFound = $false
  foreach ($forbiddenBody in @(
      $connectedCode, $replacementCode, $debugWriteCode, $ordinaryWriteCode,
      $flushCode, $flushCompleteCode, $endCode, $setTxBufferCode,
      $clearStashCode)) {
    if ($null -ne $forbiddenBody -and
        $forbiddenBody -match
          '\btx_fifo_quarantined\s*=\s*false\s*;') {
      $forbiddenClearFound = $true
      break
    }
  }
  $quarantineClearScopeValid =
      $falseAssignmentsResetOwned -and -not $forbiddenClearFound
  $checks.Add([pscustomobject][ordered]@{
      name='quarantine_clear_owned_only_by_clean_bus_reset'
      valid=$quarantineClearScopeValid
    })
  if (-not $quarantineClearScopeValid) {
    Add-Failure ('tx_fifo_quarantined can be cleared outside the reset ' +
        'helper (for example by isCDC/time/end/flush/buffer resize)')
  }

  $diagnosticRecordMacroScoped =
      $hwcdcText -match
        '#if\s+defined\(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\)' -and
      $hwcdcText -match '#include\s+"HWCDCR19Diagnostic\.h"' -and
      $hwcdcText -match
        'vc_lora_r19_hwcdc_fifo_diagnostic_record' -and
      $hwcdcText -notmatch
        '(?s)#else\s+[^#]*vc_lora_r19_hwcdc_fifo_diagnostic_record'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_macro_scoped'
      valid=$diagnosticRecordMacroScoped
    })
  if (-not $diagnosticRecordMacroScoped) {
    Add-Failure 'Endpoint FIFO diagnostic record is absent or not macro scoped'
  }

  $diagnosticRecordFixedAbi =
      $diagnosticHeaderText -match
        'r19_hwcdc_fifo_diagnostic_schema\s*=\s*2U' -and
      $diagnosticHeaderText -match 'storage_word_count\s*=\s*28U' -and
      $diagnosticHeaderText -match '0x48313946U' -and
      $diagnosticHeaderText -match
        'sizeof\(R19HwcdcFifoDiagnosticRecord\)' -and
      $diagnosticHeaderText -match 'active_writer_' -and
      $diagnosticHeaderText -match 'last_flush_blocker_mask_' -and
      $diagnosticHeaderText -match 'last_flush_outcome_' -and
      $diagnosticHeaderText -match 'last_flush_task_zlp_count_' -and
      $diagnosticHeaderText -match 'last_flush_isr_zlp_count_' -and
      $diagnosticHeaderText -match
        'last_flush_terminal_blocker_mask_'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_fixed_abi'
      valid=$diagnosticRecordFixedAbi
    })
  if (-not $diagnosticRecordFixedAbi) {
    Add-Failure ('Endpoint FIFO diagnostic record is not the append-only ' +
        'schema-2 28-word ABI')
  }

  $diagnosticTracksWriteAndWrDone =
      ([regex]::Matches($hwcdcCode, '\.record_fifo_write\s*\(').Count -ge 2) -and
      (([regex]::Matches($hwcdcCode, '\.record_wr_done\s*\(').Count +
        [regex]::Matches($hwcdcCode,
          '\.record_zlp_wr_done\s*\(').Count) -ge 3) -and
      $diagnosticHeaderText -match 'fifo_write_bytes_' -and
      $diagnosticHeaderText -match 'fifo_zero_write_count_' -and
      $diagnosticHeaderText -match 'wr_done_count_'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_tracks_fifo_write_and_wr_done'
      valid=$diagnosticTracksWriteAndWrDone
    })
  if (-not $diagnosticTracksWriteAndWrDone) {
    Add-Failure 'Endpoint FIFO write and wr_done evidence is incomplete'
  }

  $diagnosticDistinguishesInEmpty =
      $hwcdcCode -match
        'record_in_empty\s*\(\s*payload_pickup_allowed\s*,' -and
      $diagnosticHeaderText -match
        'if\s*\(\s*payload_pickup\s*\)[\s\S]*?' +
        'saturating_increment\s*\(\s*payload_in_empty_count_\s*\)' -and
      $diagnosticHeaderText -match
        'raw_in_empty_pending[\s\S]*?' +
        'saturating_increment\s*\(\s*in_empty_irq_count_\s*\)' -and
      $diagnosticHeaderText -match 'in_empty_irq_count_' -and
      $diagnosticHeaderText -match 'payload_in_empty_count_'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup'
      valid=$diagnosticDistinguishesInEmpty
    })
  if (-not $diagnosticDistinguishesInEmpty) {
    Add-Failure 'Raw IN_EMPTY is not separated from payload pickup evidence'
  }

  $diagnosticTracksResetAndFlush =
      $hwcdcCode -match '\.record_bus_reset\s*\(' -and
      $hwcdcCode -match '\.record_flush_attempt\s*\(' -and
      $hwcdcCode -match '\.record_flush_success\s*\(' -and
      $hwcdcCode -match '\.record_flush_timeout\s*\(' -and
      $hwcdcCode -match '\.record_flush_abort\s*\(' -and
      $diagnosticHeaderText -match 'FlushActive' -and
      $diagnosticHeaderText -match 'publish_generation_' -and
      $diagnosticHeaderText -match 'pickup_generation_' -and
      $diagnosticHeaderText -match 'bus_reset_count_' -and
      $diagnosticHeaderText -match 'last_flush_blocker_mask_'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome'
      valid=$diagnosticTracksResetAndFlush
    })
  if (-not $diagnosticTracksResetAndFlush) {
    Add-Failure 'Generation, reset, or flush outcome evidence is incomplete'
  }

  $taskZlpHelperBody = Get-FunctionBody $hwcdcText `
      'static\s+inline\s+bool\s+hw_cdc_flush_txfifo_if_safe\s*\(\s*void\s*\)'
  $terminalZlpHelperBody = Get-FunctionBody $hwcdcText `
      ('static\s+inline\s+bool\s+' +
       'hw_cdc_r19_issue_terminal_zlp_locked\s*\(')
  $isrBody = Get-FunctionBody $hwcdcText `
      'static\s+void\s+hw_cdc_isr_handler\s*\(\s*void\s*\*\s*arg\s*\)'
  $cdc0WriteCharBody = Get-FunctionBody $hwcdcText `
      'static\s+void\s+ARDUINO_ISR_ATTR\s+cdc0_write_char\s*\(\s*char\s+\w+\s*\)'
  $diagnosticTracksAttemptZlpOrigins =
      $diagnosticHeaderText -match
        'enum\s+class\s+R19HwcdcFifoZlpOrigin' -and
      $diagnosticHeaderText -match
        'record_zlp_wr_done\s*\(' -and
      $null -ne $taskZlpHelperBody -and
      $taskZlpHelperBody -match '\bxPortInIsrContext\s*\(' -and
      $taskZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Task' -and
      $taskZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Isr' -and
      $taskZlpHelperBody -match 'record_zlp_wr_done\s*\(' -and
      $null -ne $terminalZlpHelperBody -and
      $terminalZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Task' -and
      $terminalZlpHelperBody -match 'record_zlp_wr_done\s*\(' -and
      $null -ne $cdc0WriteCharBody -and
      $cdc0WriteCharBody -match '\bxPortInIsrContext\s*\(' -and
      $cdc0WriteCharBody -match 'hw_cdc_flush_txfifo_if_safe\s*\(' -and
      $null -ne $isrBody -and
      $isrBody -notmatch 'record_zlp_wr_done\s*\(' -and
      $isrEmptyCompletionQuiescent
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_record_tracks_per_attempt_zlp_origins'
      valid=$diagnosticTracksAttemptZlpOrigins
    })
  if (-not $diagnosticTracksAttemptZlpOrigins) {
    Add-Failure ('Per-attempt task/ISR ZLP origin evidence is absent or ' +
        'wired to the wrong HWCDC execution context')
  }

  $atomicZlpWrDoneBody = Get-FunctionBody $diagnosticHeaderText `
      'record_zlp_wr_done\s*\('
  $atomicZlpBeginPosition = if ($null -ne $atomicZlpWrDoneBody) {
    $atomicZlpWrDoneBody.IndexOf('begin_write')
  } else { -1 }
  $atomicZlpActionPosition = if ($null -ne $atomicZlpWrDoneBody) {
    $atomicZlpWrDoneBody.IndexOf('flush_and_sample()')
  } else { -1 }
  $atomicZlpCounterPosition = if ($null -ne $atomicZlpWrDoneBody) {
    $atomicZlpWrDoneBody.IndexOf('saturating_increment(wr_done_count_)')
  } else { -1 }
  $atomicZlpCommitPosition = if ($null -ne $atomicZlpWrDoneBody) {
    $atomicZlpWrDoneBody.LastIndexOf('commit_write')
  } else { -1 }
  $atomicZlpPublishRejectPosition = if ($null -ne $atomicZlpWrDoneBody) {
    $atomicZlpWrDoneBody.IndexOf('if (!publish_record)')
  } else { -1 }
  $taskZlpRecordPosition = if ($null -ne $taskZlpHelperBody) {
    $taskZlpHelperBody.IndexOf('record_zlp_wr_done')
  } else { -1 }
  $taskZlpHardwarePosition = if ($null -ne $taskZlpHelperBody) {
    $taskZlpHelperBody.LastIndexOf('usb_serial_jtag_ll_txfifo_flush')
  } else { -1 }
  $terminalZlpRecordPosition = if ($null -ne $terminalZlpHelperBody) {
      $terminalZlpHelperBody.IndexOf('record_zlp_wr_done')
    } else { -1 }
  $terminalZlpHardwarePosition = if ($null -ne $terminalZlpHelperBody) {
      $terminalZlpHelperBody.LastIndexOf('usb_serial_jtag_ll_txfifo_flush')
    } else { -1 }
  $diagnosticCommitsZlpOriginAtomically =
      $diagnosticHeaderText -match
        'enum\s+class\s+R19HwcdcFifoZlpOrigin' -and
      $null -ne $atomicZlpWrDoneBody -and
      ([regex]::Matches($atomicZlpWrDoneBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($atomicZlpWrDoneBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $atomicZlpBeginPosition -ge 0 -and
      $atomicZlpActionPosition -gt $atomicZlpBeginPosition -and
      $atomicZlpPublishRejectPosition -gt $atomicZlpActionPosition -and
      $atomicZlpCounterPosition -gt $atomicZlpActionPosition -and
      $atomicZlpCommitPosition -gt $atomicZlpCounterPosition -and
      $atomicZlpWrDoneBody -match
        'saturating_increment\s*\(\s*wr_done_count_\s*\)' -and
      $atomicZlpWrDoneBody -match
        'saturating_increment\s*\(\s*zlp_flush_count_\s*\)' -and
      $atomicZlpWrDoneBody -match
        'last_flush_task_zlp_count_' -and
      $atomicZlpWrDoneBody -match
        'last_flush_isr_zlp_count_' -and
      $atomicZlpWrDoneBody -match '\bflush_active\s*\(' -and
      $null -ne $taskZlpHelperBody -and
      $taskZlpHelperBody -match '\bxPortInIsrContext\s*\(' -and
      $taskZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Task' -and
      $taskZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Isr' -and
      $taskZlpHelperBody -match 'record_zlp_wr_done\s*\(' -and
      $null -ne $terminalZlpHelperBody -and
      $terminalZlpHelperBody -match 'R19HwcdcFifoZlpOrigin::Task' -and
      $terminalZlpHelperBody -match 'record_zlp_wr_done\s*\(' -and
      $null -ne $isrBody -and
      $isrBody -notmatch 'record_zlp_wr_done\s*\(' -and
      ([regex]::Matches($hwcdcCode,
          '\.record_zlp_wr_done\s*\(').Count -eq 2) -and
      $hwcdcCode -notmatch 'record_wr_done\s*\(\s*true\s*,' -and
      $hwcdcCode -notmatch 'record_flush_(?:task|isr)_zlp\s*\(' -and
      $diagnosticHeaderText -notmatch
        'record_flush_(?:task|isr)_zlp\s*\('
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_zlp_wr_done_origin_is_one_seqlock_transaction'
      valid=$diagnosticCommitsZlpOriginAtomically
    })
  if (-not $diagnosticCommitsZlpOriginAtomically) {
    Add-Failure ('ZLP WR_DONE cumulative and attempt-origin evidence is not ' +
        'committed by one origin-qualified diagnostic mutator')
  }

  $diagnosticZlpHardwareBoundaryFailClosed =
      $null -ne $taskZlpHelperBody -and
      $taskZlpHelperBody -match
        'record_zlp_wr_done\s*\(\s*zlp_origin\s*,\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $taskZlpRecordPosition -ge 0 -and
      $taskZlpHardwarePosition -gt $taskZlpRecordPosition -and
      $null -ne $terminalZlpHelperBody -and
      $terminalZlpHelperBody -match
        'record_zlp_wr_done\s*\(\s*R19HwcdcFifoZlpOrigin::Task\s*,' -and
      $terminalZlpRecordPosition -ge 0 -and
      $terminalZlpHardwarePosition -gt $terminalZlpRecordPosition -and
      $null -ne $isrBody -and
      $isrBody -notmatch 'record_zlp_wr_done\s*\(' -and
      ([regex]::Matches($hwcdcCode,
          '\.record_zlp_wr_done\s*\(').Count -eq 2)
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_zlp_hardware_boundary_is_fail_closed'
      expected='seqlock odd from immediately before hardware flush through accounting commit'
      valid=$diagnosticZlpHardwareBoundaryFailClosed
    })
  if (-not $diagnosticZlpHardwareBoundaryFailClosed) {
    Add-Failure ('ZLP hardware flush occurs outside the diagnostic seqlock ' +
        'transaction, allowing JTAG to accept a stable undercount')
  }

  $diagnosticZlpInvalidStateFailClosed =
      $null -ne $atomicZlpWrDoneBody -and
      $atomicZlpWrDoneBody -match
        'if\s*\(\s*!\s*state_valid\s*\)\s*\{[\s\S]*?' +
        'magic_\s*=\s*0U\s*;[\s\S]*?' +
        'schema_\s*=\s*0U\s*;' -and
      $atomicZlpActionPosition -ge 0 -and
      $atomicZlpPublishRejectPosition -gt $atomicZlpActionPosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_zlp_invalid_post_state_is_fail_closed'
      expected='hardware action always runs; invalid post-state invalidates record header'
      valid=$diagnosticZlpInvalidStateFailClosed
    })
  if (-not $diagnosticZlpInvalidStateFailClosed) {
    Add-Failure ('ZLP hardware action can leave a stable valid record with ' +
        'stale state, or can be skipped when diagnostics are uninitialized')
  }

  $atomicPayloadWrDoneBody = Get-FunctionBody $diagnosticHeaderText `
      'record_wr_done\s*\('
  $atomicPayloadBeginPosition = if ($null -ne $atomicPayloadWrDoneBody) {
    $atomicPayloadWrDoneBody.IndexOf('begin_write')
  } else { -1 }
  $atomicPayloadActionPosition = if ($null -ne $atomicPayloadWrDoneBody) {
    $atomicPayloadWrDoneBody.IndexOf('flush_and_sample()')
  } else { -1 }
  $atomicPayloadPublishRejectPosition =
      if ($null -ne $atomicPayloadWrDoneBody) {
        $atomicPayloadWrDoneBody.IndexOf('if (!publish_record)')
      } else { -1 }
  $atomicPayloadCounterPosition = if ($null -ne $atomicPayloadWrDoneBody) {
    $atomicPayloadWrDoneBody.IndexOf('saturating_increment(wr_done_count_)')
  } else { -1 }
  $atomicPayloadCommitPosition = if ($null -ne $atomicPayloadWrDoneBody) {
    $atomicPayloadWrDoneBody.LastIndexOf('commit_write')
  } else { -1 }
  $isrPayloadWriteForWrDonePosition = if ($null -ne $isrBody) {
    $isrBody.IndexOf(
        'usb_serial_jtag_ll_write_txfifo(queued_buff, queued_size)')
  } else { -1 }
  $isrPayloadWrDonePosition = if ($isrPayloadWriteForWrDonePosition -ge 0) {
    $isrBody.IndexOf('record_wr_done', $isrPayloadWriteForWrDonePosition)
  } else { -1 }
  $isrPayloadHardwarePosition = if ($isrPayloadWriteForWrDonePosition -ge 0) {
    $isrBody.IndexOf(
        'usb_serial_jtag_ll_txfifo_flush',
        $isrPayloadWriteForWrDonePosition)
  } else { -1 }
  $bootstrapPayloadWrDonePosition =
      if ($null -ne $bootstrapBody -and $bootstrapHeadWritePosition -ge 0) {
        $bootstrapBody.IndexOf(
            'record_wr_done', $bootstrapHeadWritePosition)
      } else { -1 }
  $bootstrapPayloadHardwarePosition =
      if ($null -ne $bootstrapBody -and $bootstrapHeadWritePosition -ge 0) {
        $bootstrapBody.IndexOf(
            'usb_serial_jtag_ll_txfifo_flush',
            $bootstrapHeadWritePosition)
      } else { -1 }
  $diagnosticPayloadHardwareBoundaryFailClosed =
      $null -ne $atomicPayloadWrDoneBody -and
      ([regex]::Matches($atomicPayloadWrDoneBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($atomicPayloadWrDoneBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $atomicPayloadBeginPosition -ge 0 -and
      $atomicPayloadActionPosition -gt $atomicPayloadBeginPosition -and
      $atomicPayloadPublishRejectPosition -gt $atomicPayloadActionPosition -and
      $atomicPayloadCounterPosition -gt $atomicPayloadActionPosition -and
      $atomicPayloadCommitPosition -gt $atomicPayloadCounterPosition -and
      $atomicPayloadWrDoneBody -match
        'if\s*\(\s*!\s*state_valid\s*\)\s*\{[\s\S]*?' +
        'magic_\s*=\s*0U\s*;[\s\S]*?' +
        'schema_\s*=\s*0U\s*;' -and
      $null -ne $isrBody -and
      $isrBody -match
        'record_wr_done\s*\(\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $isrPayloadWrDonePosition -ge 0 -and
      $isrPayloadHardwarePosition -gt $isrPayloadWrDonePosition -and
      $null -ne $bootstrapBody -and
      $bootstrapBody -match
        'record_wr_done\s*\(\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $bootstrapPayloadWrDonePosition -ge 0 -and
      $bootstrapPayloadHardwarePosition -gt
        $bootstrapPayloadWrDonePosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_payload_wr_done_hardware_boundary_is_fail_closed'
      expected=('seqlock odd before payload hardware flush through exact ' +
        'WR_DONE/state commit at ISR and bootstrap callsites')
      valid=$diagnosticPayloadHardwareBoundaryFailClosed
    })
  if (-not $diagnosticPayloadHardwareBoundaryFailClosed) {
    Add-Failure ('Payload hardware flush occurs outside the diagnostic ' +
        'WR_DONE seqlock transaction, can skip hardware when uninitialized, ' +
        'or can republish stale state after an invalid post-flush sample')
  }

  $atomicFifoWriteBody = Get-FunctionBody $diagnosticHeaderText `
      'record_fifo_write\s*\('
  $atomicFifoWriteBeginPosition = if ($null -ne $atomicFifoWriteBody) {
    $atomicFifoWriteBody.IndexOf('begin_write')
  } else { -1 }
  $atomicFifoWriteActionPosition = if ($null -ne $atomicFifoWriteBody) {
    $atomicFifoWriteBody.IndexOf('write_and_sample()')
  } else { -1 }
  $atomicFifoWriteRejectPosition = if ($null -ne $atomicFifoWriteBody) {
    $atomicFifoWriteBody.IndexOf('if (!publish_record)')
  } else { -1 }
  $atomicFifoWriteCounterPosition = if ($null -ne $atomicFifoWriteBody) {
    $atomicFifoWriteBody.IndexOf(
        'saturating_increment(fifo_write_attempt_count_)')
  } else { -1 }
  $atomicFifoWriteCommitPosition = if ($null -ne $atomicFifoWriteBody) {
    $atomicFifoWriteBody.LastIndexOf('commit_write')
  } else { -1 }
  $isrFifoRecordPosition = if ($null -ne $isrBody) {
    $isrBody.IndexOf('record_fifo_write')
  } else { -1 }
  $bootstrapFifoRecordPosition =
      if ($null -ne $bootstrapBody) {
        $bootstrapBody.IndexOf('record_fifo_write')
      } else { -1 }
  $diagnosticFifoWriteHardwareBoundaryFailClosed =
      $diagnosticHeaderText -match
        'struct\s+R19HwcdcFifoWriteResult\s+final' -and
      $null -ne $atomicFifoWriteBody -and
      ([regex]::Matches($atomicFifoWriteBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($atomicFifoWriteBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $atomicFifoWriteBeginPosition -ge 0 -and
      $atomicFifoWriteActionPosition -gt $atomicFifoWriteBeginPosition -and
      $atomicFifoWriteRejectPosition -gt $atomicFifoWriteActionPosition -and
      $atomicFifoWriteCounterPosition -gt $atomicFifoWriteActionPosition -and
      $atomicFifoWriteCommitPosition -gt $atomicFifoWriteCounterPosition -and
      $atomicFifoWriteBody -match
        'if\s*\(\s*!\s*result_valid\s*\)\s*\{[\s\S]*?' +
        'magic_\s*=\s*0U\s*;[\s\S]*?' +
        'schema_\s*=\s*0U\s*;' -and
      $null -ne $isrBody -and
      $isrBody -match
        'record_fifo_write\s*\(\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $isrFifoRecordPosition -ge 0 -and
      $isrPayloadWriteForWrDonePosition -gt $isrFifoRecordPosition -and
      $null -ne $bootstrapBody -and
      $bootstrapBody -match
        'record_fifo_write\s*\(\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $bootstrapFifoRecordPosition -ge 0 -and
      $bootstrapHeadWritePosition -gt $bootstrapFifoRecordPosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_fifo_write_hardware_boundary_is_fail_closed'
      expected=('seqlock odd before write_txfifo through exact byte/state ' +
        'commit at ISR and bootstrap callsites')
      valid=$diagnosticFifoWriteHardwareBoundaryFailClosed
    })
  if (-not $diagnosticFifoWriteHardwareBoundaryFailClosed) {
    Add-Failure ('FIFO hardware write occurs outside the diagnostic seqlock ' +
        'transaction or can leave stable stale accounting/state')
  }

  $atomicInEmptyBody = Get-FunctionBody $diagnosticHeaderText `
      'record_in_empty\s*\('
  $atomicInEmptyBeginPosition = if ($null -ne $atomicInEmptyBody) {
    $atomicInEmptyBody.IndexOf('begin_write')
  } else { -1 }
  $atomicInEmptyActionPosition = if ($null -ne $atomicInEmptyBody) {
    $atomicInEmptyBody.IndexOf('process_and_sample()')
  } else { -1 }
  $atomicInEmptyRejectPosition = if ($null -ne $atomicInEmptyBody) {
    $atomicInEmptyBody.IndexOf('if (!publish_record)')
  } else { -1 }
  $atomicInEmptyCounterPosition = if ($null -ne $atomicInEmptyBody) {
    $atomicInEmptyBody.IndexOf('saturating_increment(in_empty_irq_count_)')
  } else { -1 }
  $atomicInEmptyCommitPosition = if ($null -ne $atomicInEmptyBody) {
    $atomicInEmptyBody.LastIndexOf('commit_write')
  } else { -1 }
  $isrInEmptyRecordPosition = if ($null -ne $isrBody) {
    $isrBody.IndexOf('record_in_empty')
  } else { -1 }
  $isrInEmptyLambdaBody = if ($null -ne $isrBody) {
    Get-FunctionBody $isrBody `
        ('record_in_empty\s*\(\s*payload_pickup_allowed\s*,\s*' +
         '\[&\]\s*\(\s*\)\s*noexcept')
  } else { $null }
  $isrConnectedActionPosition = if ($null -ne $isrInEmptyLambdaBody) {
    $isrInEmptyLambdaBody.IndexOf('connected = true')
  } else { -1 }
  $isrInEmptyClearPosition = if ($null -ne $isrInEmptyLambdaBody) {
    $isrInEmptyLambdaBody.IndexOf('usb_serial_jtag_ll_clr_intsts_mask')
  } else { -1 }
  $isrInEmptyPayloadBranchPosition = if ($null -ne $isrInEmptyLambdaBody) {
    $isrInEmptyLambdaBody.IndexOf('if (payload_pickup_allowed)')
  } else { -1 }
  $isrInEmptyDisablePosition = if ($null -ne $isrInEmptyLambdaBody) {
    $isrInEmptyLambdaBody.IndexOf('usb_serial_jtag_ll_disable_intr_mask')
  } else { -1 }
  $isrInEmptyOuterClearIsMacroOffOnly =
      $null -ne $isrBody -and
      $isrBody -match
        ('#if\s+!defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' +
         '\s*\|\|\s*!VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*' +
         'usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
         'USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)\s*;\s*#endif')
  $diagnosticInEmptyBoundaryFailClosed =
      $null -ne $atomicInEmptyBody -and
      ([regex]::Matches($atomicInEmptyBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($atomicInEmptyBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $atomicInEmptyBeginPosition -ge 0 -and
      $atomicInEmptyActionPosition -gt $atomicInEmptyBeginPosition -and
      $atomicInEmptyRejectPosition -gt $atomicInEmptyActionPosition -and
      $atomicInEmptyCounterPosition -gt $atomicInEmptyActionPosition -and
      $atomicInEmptyCommitPosition -gt $atomicInEmptyCounterPosition -and
      $atomicInEmptyBody -match
        'if\s*\(\s*!\s*state_valid\s*\)\s*\{[\s\S]*?' +
        'magic_\s*=\s*0U\s*;[\s\S]*?' +
        'schema_\s*=\s*0U\s*;' -and
      $null -ne $isrBody -and
      ([regex]::Matches($isrBody, '\.record_in_empty\s*\(').Count -eq 1) -and
      $isrBody -match
        'record_in_empty\s*\(\s*payload_pickup_allowed\s*,\s*' +
        '\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $null -ne $isrInEmptyLambdaBody -and
      ([regex]::Matches($isrInEmptyLambdaBody,
          '\busb_serial_jtag_ll_clr_intsts_mask\s*\(').Count -eq 1) -and
      $isrInEmptyRecordPosition -ge 0 -and
      $isrInEmptyClearPosition -ge 0 -and
      $isrInEmptyPayloadBranchPosition -gt $isrInEmptyClearPosition -and
      $isrConnectedActionPosition -gt $isrInEmptyPayloadBranchPosition -and
      $isrInEmptyDisablePosition -gt $isrInEmptyPayloadBranchPosition -and
      $isrInEmptyOuterClearIsMacroOffOnly
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_in_empty_side_effect_boundary_is_fail_closed'
      expected=('one callback transaction contains connected/generation or ' +
        'clear/mask side effects and raw/payload IN_EMPTY accounting')
      valid=$diagnosticInEmptyBoundaryFailClosed
    })
  if (-not $diagnosticInEmptyBoundaryFailClosed) {
    Add-Failure ('Processed IN_EMPTY side effects occur outside their single ' +
        'raw/payload diagnostic transaction')
  }

  $atomicBusResetBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_bus_reset\s*\('
  $atomicBusResetBeginPosition = if ($null -ne $atomicBusResetBody) {
    $atomicBusResetBody.IndexOf('begin_write')
  } else { -1 }
  $atomicBusResetActionPosition = if ($null -ne $atomicBusResetBody) {
    $atomicBusResetBody.IndexOf('reset_and_sample()')
  } else { -1 }
  $atomicBusResetRejectPosition = if ($null -ne $atomicBusResetBody) {
    $atomicBusResetBody.IndexOf('if (!publish_record)')
  } else { -1 }
  $atomicBusResetCounterPosition = if ($null -ne $atomicBusResetBody) {
    $atomicBusResetBody.IndexOf('saturating_increment(bus_reset_count_)')
  } else { -1 }
  $atomicBusResetCommitPosition = if ($null -ne $atomicBusResetBody) {
    $atomicBusResetBody.LastIndexOf('commit_write')
  } else { -1 }
  $resetCallbackDefinitionPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf('auto reset_and_sample')
  } else { -1 }
  $resetRecordPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf('record_bus_reset')
  } else { -1 }
  $resetClearPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf(
        'usb_serial_jtag_ll_clr_intsts_mask',
        $resetCallbackDefinitionPosition)
  } else { -1 }
  $resetEpochPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf(
        'tx_loss_epoch = tx_loss_epoch + 1U',
        $resetCallbackDefinitionPosition)
  } else { -1 }
  $resetConnectedPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf(
        'connected = false', $resetCallbackDefinitionPosition)
  } else { -1 }
  $resetSourceStatusPosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf(
        'const uint32_t source_interrupt_status',
        $resetCallbackDefinitionPosition)
  } else { -1 }
  $resetPostStatePosition = if ($null -ne $resetDiscardCode) {
    $resetDiscardCode.IndexOf(
        'hw_cdc_r19_diagnostic_state_locked()',
        $resetConnectedPosition)
  } else { -1 }
  $resetResultCarriesSourceAndPostState =
      $diagnosticHeaderCode -match
        ('struct\s+R19HwcdcFifoBusResetResult\s+final\s*\{' +
         '[\s\S]*?source_interrupt_status') -and
      $null -ne $atomicBusResetBody -and
      $atomicBusResetBody -match
        ('write_state\s*\(\s*result\.state\s*\)\s*;' +
         '[\s\S]*?clear_payload_publish_pending\s*\(\s*\)\s*;' +
         '[\s\S]*?last_interrupt_status_\s*=\s*' +
         'result\.source_interrupt_status\s*;') -and
      $null -ne $resetDiscardCode -and
      $resetDiscardCode -match
        ('R19HwcdcFifoBusResetResult\s*\{\s*' +
         'raw_in_empty_pending\s*,\s*source_interrupt_status\s*,\s*' +
         'hw_cdc_r19_diagnostic_state_locked\s*\(\s*\)\s*\}')
  $resetClearsCoPendingInEmpty =
      $null -ne $resetDiscardCode -and
      $resetDiscardCode -match
        'usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
        'USB_SERIAL_JTAG_INTR_BUS_RESET\s*\|\s*' +
        'USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)'
  $resetInEmptyClearDiagnosticOnly =
      $null -ne $resetDiscardCode -and
      $resetDiscardCode -match
        ('(?s)#if\s+defined\(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\)' +
         '\s*&&\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS[\s\S]*?' +
         'usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
         'USB_SERIAL_JTAG_INTR_BUS_RESET\s*\|\s*' +
         'USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY\s*\)\s*;[\s\S]*?' +
         '#else\s*usb_serial_jtag_ll_clr_intsts_mask\s*\(\s*' +
         'USB_SERIAL_JTAG_INTR_BUS_RESET\s*\)\s*;\s*#endif')
  $lateResetCallerDoesNotDuplicateDisconnect =
      $null -ne $completionResetBlock -and
      $completionResetBlock -notmatch 'connected\s*=\s*false\s*;'
  $diagnosticBusResetBoundaryFailClosed =
      $diagnosticHeaderText -match
        'struct\s+R19HwcdcFifoBusResetResult\s+final' -and
      $null -ne $atomicBusResetBody -and
      ([regex]::Matches($atomicBusResetBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($atomicBusResetBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $atomicBusResetBeginPosition -ge 0 -and
      $atomicBusResetActionPosition -gt $atomicBusResetBeginPosition -and
      $atomicBusResetRejectPosition -gt $atomicBusResetActionPosition -and
      $atomicBusResetCounterPosition -gt $atomicBusResetActionPosition -and
      $atomicBusResetCommitPosition -gt $atomicBusResetCounterPosition -and
      $atomicBusResetBody -match
        'raw_in_empty_pending[\s\S]*?' +
        'saturating_increment\s*\(\s*in_empty_irq_count_\s*\)' -and
      $atomicBusResetBody -match
        'if\s*\(\s*!\s*result_valid\s*\)\s*\{[\s\S]*?' +
        'magic_\s*=\s*0U\s*;[\s\S]*?' +
        'schema_\s*=\s*0U\s*;' -and
      $null -ne $resetDiscardCode -and
      ([regex]::Matches($resetDiscardCode,
          '\.record_bus_reset\s*\(').Count -eq 1) -and
      ([regex]::Matches($resetDiscardCode,
          '\.record_in_empty\s*\(').Count -eq 0) -and
      $resetDiscardCode -match
        'auto\s+reset_and_sample\s*=\s*\[&\]\s*\(\s*\)\s*noexcept\s*\{' -and
      $resetDiscardCode -match
        'record_bus_reset\s*\(\s*reset_and_sample\s*\)' -and
      $resetClearsCoPendingInEmpty -and
      $resetInEmptyClearDiagnosticOnly -and
      $lateResetCallerDoesNotDuplicateDisconnect -and
      $resetCallbackDefinitionPosition -ge 0 -and
      $resetClearPosition -gt $resetCallbackDefinitionPosition -and
      $resetEpochPosition -gt $resetClearPosition -and
      $resetConnectedPosition -gt $resetEpochPosition -and
      $resetSourceStatusPosition -ge $resetCallbackDefinitionPosition -and
      $resetSourceStatusPosition -lt $resetClearPosition -and
      $resetPostStatePosition -gt $resetConnectedPosition -and
      $resetResultCarriesSourceAndPostState -and
      $resetRecordPosition -gt $resetConnectedPosition
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_bus_reset_and_raw_in_empty_boundary_is_fail_closed'
      expected=('one callback transaction contains BUS_RESET and IN_EMPTY ' +
        'status clear, queue/stash/epoch/quarantine/disconnect, plus optional ' +
        'co-pending raw IN_EMPTY accounting; source status is retained while ' +
        'flags/blockers are freshly sampled after clear; extra IN_EMPTY ' +
        'clear is diagnostic-only and callers do not repeat disconnect')
      valid=$diagnosticBusResetBoundaryFailClosed
    })
  if (-not $diagnosticBusResetBoundaryFailClosed) {
    Add-Failure ('BUS_RESET side effects and co-pending raw IN_EMPTY are not ' +
        'one fail-closed diagnostic transaction')
  }

  $fifoWriteRecordBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_fifo_write\s*\('
  $payloadWrDoneRecordBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_wr_done\s*\('
  $zlpWrDoneRecordBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_zlp_wr_done\s*\('
  $payloadInEmptyRecordBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_in_empty\s*\('
  $causalInvariantHelper = Get-FunctionBody $diagnosticHeaderCode `
      '\[\[nodiscard\]\]\s+bool\s+accounting_invariants_hold\s*\('
  $causalInvariantDefined =
      $null -ne $causalInvariantHelper -and
      $causalInvariantHelper -match
        'wr_done\s*=\s*wr_done_count_' -and
      $causalInvariantHelper -match
        'zlp_flushes\s*=\s*zlp_flush_count_' -and
      $causalInvariantHelper -match 'wr_done\s*<\s*zlp_flushes' -and
      $causalInvariantHelper -match
        'fifo_write_attempts\s*<\s*fifo_zero_writes' -and
      $causalInvariantHelper -match
        'payload_in_empty_count_\s*<=\s*non_zlp_wr_done' -and
      $causalInvariantHelper -match
        'non_zlp_wr_done\s*<=\s*positive_fifo_writes'
  $causalMutatorsFailClosed = $causalInvariantDefined
  foreach ($causalBody in @(
      $fifoWriteRecordBody, $payloadWrDoneRecordBody,
      $zlpWrDoneRecordBody, $payloadInEmptyRecordBody)) {
    if ($null -eq $causalBody -or
        $causalBody -notmatch 'accounting_invariants_hold\s*\(\s*\)' -or
        ($causalBody -notmatch 'poison_current_write\s*\(\s*\)' -and
         $causalBody -notmatch
           'magic_\s*=\s*0U\s*;[\s\S]*?schema_\s*=\s*0U\s*;')) {
      $causalMutatorsFailClosed = $false
      break
    }
  }
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_payload_causal_accounting_is_fail_closed'
      expected=('every valid record satisfies payload_in_empty <= ' +
        '(wr_done-zlp) <= (fifo_attempt-zero_write); causal mutators poison ' +
        'instead of publishing an impossible ordering')
      valid=$causalMutatorsFailClosed
    })
  if (-not $causalMutatorsFailClosed) {
    Add-Failure ('HWCDC diagnostic counters can publish an impossible ' +
        'FIFO/WR_DONE/payload pickup causal ordering')
  }

  $payloadPublishAbortBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_payload_publish_abort\s*\('
  $taskDiscardBody = Get-FunctionBody $hwcdcCode `
      'static\s+void\s+hw_cdc_discard_tx_from_task_locked\s*\('
  $writeStateBody = Get-FunctionBody $diagnosticHeaderCode `
      'void\s+write_state\s*\('
  $payloadPendingFlagDefined =
      $diagnosticHeaderText -match
        'PayloadPublishPending\s*=\s*1U\s*<<\s*11U' -and
      $diagnosticHeaderText -match
        'r19_hwcdc_fifo_diagnostic_known_flag_mask\s*=\s*0x00003FFFU'
  $payloadPendingRecordOwned =
      $null -ne $writeStateBody -and
      $writeStateBody -match 'record_owned_mask' -and
      $writeStateBody -match 'FlushActive' -and
      $writeStateBody -match 'PayloadPublishPending' -and
      $diagnosticHeaderText -match
        'payload_publish_pending\s*\(\s*\)\s*const'
  $payloadPendingFifoArm =
      $null -ne $fifoWriteRecordBody -and
      $fifoWriteRecordBody -match
        'written_bytes\s*>\s*0U[\s\S]*?set_payload_publish_pending\s*\(' -and
      $fifoWriteRecordBody -match
        'payload_publish_pending\s*\(\s*\)[\s\S]*?poison_current_write'
  $payloadPendingWrDoneClear =
      $null -ne $payloadWrDoneRecordBody -and
      $payloadWrDoneRecordBody -match
        'had_payload_publish_pending' -and
      $payloadWrDoneRecordBody -match
        'flush_and_sample\s*\(\s*\)[\s\S]*?' +
        'clear_payload_publish_pending\s*\(' -and
      $payloadWrDoneRecordBody -match
        '!\s*had_payload_publish_pending'
  $payloadPendingCausalInvariant =
      $null -ne $causalInvariantHelper -and
      $causalInvariantHelper -match
        'payload_publish_pending\s*\(\s*\)[\s\S]*?' +
        'positive_fifo_writes\s*<=\s*non_zlp_wr_done'
  $payloadPendingResetAndTaskAbortClear =
      $diagnosticHeaderText -match
        'record_bus_reset[\s\S]*?clear_payload_publish_pending\s*\(' -and
      $null -ne $payloadPublishAbortBody -and
      $payloadPublishAbortBody -match
        'clear_payload_publish_pending\s*\(' -and
      $null -ne $clearStashCode -and
      $clearStashCode -match 'record_payload_publish_abort\s*\(' -and
      $null -ne $taskDiscardBody -and
      $taskDiscardBody -match 'record_payload_publish_abort\s*\('
  $payloadPendingGapClosed =
      $payloadPendingFlagDefined -and $payloadPendingRecordOwned -and
      $payloadPendingFifoArm -and $payloadPendingWrDoneClear -and
      $payloadPendingCausalInvariant -and
      $payloadPendingResetAndTaskAbortClear
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_payload_publish_pending_closes_fifo_to_wrdone_gap'
      expected=('bit-11 record-owned PayloadPublishPending is armed by each ' +
        'positive FIFO write, survives unrelated state writes, clears only ' +
        'after payload WR_DONE or an explicit reset/rollback, and prevents ' +
        'historical completion from classifying a later publish as complete')
      valid=$payloadPendingGapClosed
    })
  if (-not $payloadPendingGapClosed) {
    Add-Failure ('positive FIFO publication can expose a stable record that ' +
        'reuses historical WR_DONE/flush-success evidence before the new ' +
        'payload hardware flush completes')
  }

  $payloadAbortFlagDefined =
      $diagnosticHeaderText -match
        'PayloadPublishAborted\s*=\s*1U\s*<<\s*12U' -and
      $diagnosticHeaderText -match
        'payload_publish_aborted\s*\(\s*\)\s*const' -and
      $null -ne $writeStateBody -and
      $writeStateBody -match 'PayloadPublishAborted'
  $payloadAbortTransactionIsExact =
      $null -ne $payloadPublishAbortBody -and
      $payloadPublishAbortBody -match
        'initialized_for_writer\s*\(\s*\)' -and
      $payloadPublishAbortBody -match
        'begin_write\s*\(\s*\)[\s\S]*?abort_and_sample\s*\(\s*\)' -and
      $payloadPublishAbortBody -match
        'abort_and_sample\s*\(\s*\)[\s\S]*?set_payload_publish_aborted\s*\(' -and
      $payloadPublishAbortBody -match
        'valid_state\s*\([\s\S]*?poison_current_write\s*\(' -and
      $payloadPublishAbortBody -match
        'commit_write\s*\(\s*\)'
  $payloadAbortCallsitesAreEnclosed =
      $null -ne $clearStashCode -and
      $clearStashCode -match
        'discard_and_sample\s*=\s*\[&\]\s*\(\s*\)\s*noexcept' -and
      $clearStashCode -match
        'discard_and_sample[\s\S]*?tx_loss_epoch\s*=\s*tx_loss_epoch\s*\+\s*1U' -and
      $clearStashCode -match
        'record_payload_publish_abort\s*\(\s*discard_and_sample\s*\)' -and
      $null -ne $taskDiscardBody -and
      $taskDiscardBody -match
        'discard_and_sample\s*=\s*\[&\]\s*\(\s*\)\s*noexcept' -and
      $taskDiscardBody -match
        'discard_and_sample[\s\S]*?xRingbufferReceiveUpTo' -and
      $taskDiscardBody -match
        'record_payload_publish_abort\s*\(\s*discard_and_sample\s*\)'
  $payloadAbortSupersessionIsExplicit =
      $fifoWriteRecordBody -match
        'written_bytes\s*>\s*0U[\s\S]*?clear_payload_publish_aborted\s*\(' -and
      $diagnosticHeaderText -match
        'record_bus_reset[\s\S]*?set_payload_publish_aborted\s*\('
  $payloadAbortDominatesHistoricalSuccess =
      $payloadAbortFlagDefined -and $payloadAbortTransactionIsExact -and
      $payloadAbortCallsitesAreEnclosed -and
      $payloadAbortSupersessionIsExplicit
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_payload_publish_abort_dominates_historical_success'
      expected=('bit-12 record-owned PayloadPublishAborted spans each task ' +
        'discard side effect and state sample in one seqlock transaction, ' +
        'poisons invalid post-state, persists across BUS_RESET and unrelated ' +
        'events, and is cleared only by a newer positive publish')
      valid=$payloadAbortDominatesHistoricalSuccess
    })
  if (-not $payloadAbortDominatesHistoricalSuccess) {
    Add-Failure ('task-side payload discard can expose historical ' +
        'flush-success evidence before its abort witness is committed')
  }

  $payloadFlushSuccessBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_flush_success\s*\('
  $payloadFlushFlagDefined =
      $diagnosticHeaderText -match
        'PayloadFlushPending\s*=\s*1U\s*<<\s*13U' -and
      $diagnosticHeaderText -match
        'payload_flush_pending\s*\(\s*\)\s*const' -and
      $null -ne $writeStateBody -and
      $writeStateBody -match 'PayloadFlushPending'
  $payloadFlushArmedOnlyByPositiveWrite =
      $null -ne $fifoWriteRecordBody -and
      $fifoWriteRecordBody -match
        'written_bytes\s*>\s*0U[\s\S]*?set_payload_flush_pending\s*\('
  $payloadFlushSurvivesIntermediateEvents =
      $null -ne $payloadWrDoneRecordBody -and
      $payloadWrDoneRecordBody -notmatch 'clear_payload_flush_pending\s*\(' -and
      $null -ne $payloadInEmptyRecordBody -and
      $payloadInEmptyRecordBody -notmatch 'clear_payload_flush_pending\s*\(' -and
      $null -ne $zlpWrDoneRecordBody -and
      $zlpWrDoneRecordBody -notmatch 'clear_payload_flush_pending\s*\('
  $payloadFlushClearsOnlyOnBoundSuccess =
      $null -ne $payloadFlushSuccessBody -and
      $payloadFlushSuccessBody -match 'had_payload_flush_pending' -and
      $payloadFlushSuccessBody -match 'payload_publish_pending\s*\(' -and
      $payloadFlushSuccessBody -match 'state_has_payload_in_flight' -and
      $payloadFlushSuccessBody -match
        'state\.publish_generation\s*!=\s*state\.pickup_generation' -and
      $payloadFlushSuccessBody -match
        'had_payload_flush_pending[\s\S]*?clear_payload_flush_pending\s*\('
  $payloadFlushResetAndDiscardFailClosed =
      $diagnosticHeaderText -match (
        'record_bus_reset[\s\S]*?clear_payload_flush_pending\s*\([\s\S]*?' +
        'set_payload_publish_aborted\s*\(') -and
      $null -ne $payloadPublishAbortBody -and
      $payloadPublishAbortBody -match (
        'clear_payload_flush_pending\s*\([\s\S]*?' +
        'set_payload_publish_aborted\s*\(')
  $payloadFlushCausalInvariant =
      $null -ne $causalInvariantHelper -and
      $causalInvariantHelper -match (
        'payload_publish_pending\s*\(\s*\)[\s\S]*?' +
        '!payload_flush_pending\s*\(\s*\)') -and
      $causalInvariantHelper -match
        'payload_in_flight[\s\S]*?!payload_flush_pending\s*\(\s*\)' -and
      $causalInvariantHelper -match (
        'payload_publish_aborted\s*\(\s*\)[\s\S]*?' +
        'payload_flush_pending\s*\(\s*\)')
  $payloadFlushBindsNewSuccess =
      $payloadFlushFlagDefined -and
      $payloadFlushArmedOnlyByPositiveWrite -and
      $payloadFlushSurvivesIntermediateEvents -and
      $payloadFlushClearsOnlyOnBoundSuccess -and
      $payloadFlushResetAndDiscardFailClosed -and
      $payloadFlushCausalInvariant
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_payload_flush_pending_binds_publication_to_new_flush_success'
      expected=('bit-13 record-owned PayloadFlushPending is armed by a ' +
        'positive FIFO write, survives WR_DONE/pickup/ZLP/observation, clears ' +
        'only on a clean picked-up new flush success, and fails closed on ' +
        'reset/discard or contradictory state')
      valid=$payloadFlushBindsNewSuccess
    })
  if (-not $payloadFlushBindsNewSuccess) {
    Add-Failure ('a newly picked-up payload can reuse historical flush-success ' +
        'evidence before its own clean flush succeeds')
  }

  $lifecyclePoisonBody = Get-FunctionBody $diagnosticHeaderCode `
      '\[\[nodiscard\]\]\s+bool\s+poison_lifecycle_transition\s*\('
  $flushAttemptBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_flush_attempt\s*\('
  $flushSuccessBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_flush_success\s*\('
  $flushTimeoutBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_flush_timeout\s*\('
  $flushAbortBody = Get-FunctionBody $diagnosticHeaderCode `
      'record_flush_abort\s*\('
  $lifecycleMethodsFailClosed = $true
  foreach ($lifecycleBody in @(
      $flushAttemptBody, $flushSuccessBody,
      $flushTimeoutBody, $flushAbortBody)) {
    if ($null -eq $lifecycleBody -or
        $lifecycleBody -notmatch
          'if\s*\(\s*!\s*initialized_for_writer\s*\(\s*\)\s*\)' -or
        $lifecycleBody -notmatch
          'poison_lifecycle_transition\s*\(\s*\)') {
      $lifecycleMethodsFailClosed = $false
      break
    }
  }
  $diagnosticLifecycleTransitionsFailClosed =
      $null -ne $lifecyclePoisonBody -and
      ([regex]::Matches($lifecyclePoisonBody,
          '\bbegin_write\s*\(').Count -eq 1) -and
      ([regex]::Matches($lifecyclePoisonBody,
          '\bcommit_write\s*\(').Count -eq 1) -and
      $lifecyclePoisonBody -match 'magic_\s*=\s*0U\s*;' -and
      $lifecyclePoisonBody -match 'schema_\s*=\s*0U\s*;' -and
      $lifecyclePoisonBody -match 'flags_\s*=\s*0U\s*;' -and
      $lifecycleMethodsFailClosed -and
      $null -ne $flushSuccessBody -and
      $diagnosticHeaderCode -match
        ('record_flush_success\s*\(\s*' +
         'const\s+R19HwcdcFifoDiagnosticState&\s+state\s*,\s*' +
         'bool\s+terminal_zlp_required') -and
      $flushSuccessBody -match
        'terminal_evidence_valid\s*=\s*terminal_zlp_required' -and
      $flushSuccessBody -match
        'last_flush_task_zlp_count_\s*==\s*1U' -and
      $flushSuccessBody -match
        'last_flush_task_zlp_count_\s*==\s*0U' -and
      $flushSuccessBody -match
        '!\s*terminal_evidence_valid' -and
      $flushSuccessBody -match
        'state\.flush_blocker_mask\s*!=\s*0U' -and
      $null -ne $flushAbortBody -and
      $flushAbortBody -match
        'R19HwcdcFifoFlushBlocker::EpochMismatch'
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_flush_lifecycle_invalid_transition_is_fail_closed'
      expected=('initialized invalid/duplicate transitions poison the header; ' +
        'success requires zero blockers and requires a task ZLP only when the ' +
        'explicit full/unknown-packet policy says so; abort requires EpochMismatch')
      valid=$diagnosticLifecycleTransitionsFailClosed
    })
  if (-not $diagnosticLifecycleTransitionsFailClosed) {
    Add-Failure ('Flush lifecycle accepts impossible success/abort evidence ' +
        'or leaves a prior valid header after an invalid/duplicate transition')
  }

  $hasLossEpochApi =
      $hwcdcHeaderText -match 'uint32_t\s+txLossEpoch\s*\(\s*\)\s*const' -and
      $hwcdcText -match 'uint32_t\s+HWCDC::txLossEpoch\s*\(\s*\)\s*const'
  $checks.Add([pscustomobject][ordered]@{
      name='loss_epoch_api';valid=$hasLossEpochApi
    })
  if (-not $hasLossEpochApi) {
    Add-Failure 'HWCDC does not expose the TX-loss epoch'
  }

  $callEvidenceBody = Get-FunctionBody $hwcdcText `
      'bool\s+HWCDC::flushTxCompleteDiagnostic\s*\('
  $callEvidenceCode = Remove-CppComments $callEvidenceBody
  $callEvidenceContract =
      $null -ne $callEvidenceBody -and
      $hwcdcHeaderText -match
        '(?s)#if defined\(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\) && VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s+[^#]*flushTxCompleteDiagnostic' -and
      $diagnosticHeaderText -match
        'sizeof\(R19HwcdcFlushCallEvidence\)\s*==\s*96U' -and
      $callEvidenceCode -match 'evidence\.transaction_token\s*=\s*token' -and
      $callEvidenceCode -match 'evidence\.attempt_id\s*=\s*attempt' -and
      $callEvidenceCode -match 'evidence\.raw_return\s*=\s*result' -and
      $callEvidenceCode -match 'evidence\.lock_wait_ms' -and
      $callEvidenceCode -match 'evidence\.snapshot_duration_us' -and
      $callEvidenceCode -match
        'evidence\.raw_interrupt_status\s*=\s*usb_serial_jtag_ll_get_intraw_mask' -and
      $callEvidenceCode -match
        'evidence\.interrupt_enable_mask\s*=\s*usb_serial_jtag_ll_get_intr_ena_status'
  foreach ($terminalReason in @(
      'NullRing','NullLock','LockTimeout','LoopTimeout','EpochAbort','Success')) {
    $callEvidenceContract = $callEvidenceContract -and
      $callEvidenceCode -match ('R19HwcdcFlushTerminalReason::' + $terminalReason)
  }
  $checks.Add([pscustomobject][ordered]@{
      name='flush_call_evidence_api_fixed_abi_and_all_terminal_paths'
      expected='diagnostic-only caller-local 96-byte outcome with coherent terminal snapshot and all return reasons'
      valid=[bool]$callEvidenceContract
    })
  if (-not $callEvidenceContract) {
    Add-Failure 'Call-local HWCDC flush evidence lacks its fixed ABI, identity, timing, or a terminal return path'
  }

  $hasFlushCompleteDeclaration = $hwcdcHeaderText -match
      'bool\s+flushTxComplete\s*\(\s*uint32_t\s+timeout_ms\s*,\s*' +
      'uint32_t\s+expected_loss_epoch\s*\)'
  $flushCompleteBody = Get-FunctionBody $hwcdcText `
      'bool\s+HWCDC::flushTxComplete\s*\(\s*uint32_t\s+timeout_ms\s*,\s*uint32_t\s+expected_loss_epoch\s*\)'
  $flushCompleteExecutable = Remove-CppComments $flushCompleteBody
  $timeoutBranch = $null
  if ($null -ne $flushCompleteExecutable) {
    $timeoutBranchStart = $flushCompleteExecutable.IndexOf(
        'if (elapsed_ms >= timeout_ms)')
    $timeoutBranchEnd = if ($timeoutBranchStart -ge 0) {
      $flushCompleteExecutable.IndexOf(
          'const bool host_present', $timeoutBranchStart)
    } else { -1 }
    if ($timeoutBranchStart -ge 0 -and
        $timeoutBranchEnd -gt $timeoutBranchStart) {
      $timeoutBranch = $flushCompleteExecutable.Substring(
          $timeoutBranchStart,
          $timeoutBranchEnd - $timeoutBranchStart)
    }
  }
  $timeoutLockPosition = if ($null -ne $timeoutBranch) {
    $timeoutBranch.IndexOf('portENTER_CRITICAL_SAFE')
  } else { -1 }
  $timeoutStateSamplePosition = if ($null -ne $timeoutBranch) {
    $timeoutBranch.IndexOf(
        'terminal_state = hw_cdc_r19_diagnostic_state_locked')
  } else { -1 }
  $timeoutBlockerPosition = if ($null -ne $timeoutBranch) {
    $timeoutBranch.IndexOf('hw_cdc_r19_flush_blockers_locked')
  } else { -1 }
  $timeoutRecordPosition = if ($null -ne $timeoutBranch) {
    $timeoutBranch.IndexOf('record_flush_timeout')
  } else { -1 }
  $timeoutUnlockPosition = if ($null -ne $timeoutBranch) {
    $timeoutBranch.IndexOf('portEXIT_CRITICAL_SAFE')
  } else { -1 }
  $timeoutTerminalResampleValid =
      $null -ne $timeoutBranch -and
      $timeoutBranch -match '\bterminal_host_present\b' -and
      $timeoutBranch -match '\bterminal_state\b' -and
      $timeoutBranch -match '\bterminal_reset_pending\b' -and
      $timeoutBranch -match '\bterminal_epoch_matches\b' -and
      $timeoutBranch -match '\bterminal_software_empty\b' -and
      $timeoutBranch -match '\bterminal_fifo_writable\b' -and
      $timeoutBranch -match '\bterminal_payload_pickup_complete\b' -and
      $timeoutBranch -match '\bterminal_flush_blocker_mask\b' -and
      $timeoutBranch -match
        'terminal_state\.flush_blocker_mask\s*=\s*terminal_flush_blocker_mask' -and
      $timeoutBranch -match
        'record_flush_timeout\s*\(\s*terminal_state\s*\)' -and
      $timeoutBranch -notmatch '\blast_flush_blocker_mask\b' -and
      $timeoutLockPosition -ge 0 -and
      $timeoutStateSamplePosition -gt $timeoutLockPosition -and
      $timeoutBlockerPosition -gt $timeoutStateSamplePosition -and
      $timeoutRecordPosition -gt $timeoutBlockerPosition -and
      $timeoutUnlockPosition -gt $timeoutRecordPosition
  $checks.Add([pscustomobject][ordered]@{
      name='timeout_terminal_blockers_resampled_under_lock'
      expected='fresh terminal state and blocker mask recorded in timeout transaction'
      valid=$timeoutTerminalResampleValid
    })
  if (-not $timeoutTerminalResampleValid) {
    Add-Failure ('flushTxComplete timeout records stale loop blockers instead ' +
        'of resampling terminal state under the TX lock')
  }
  $finalFifoSamplePosition = if ($null -ne $flushCompleteBody) {
    $flushCompleteBody.IndexOf('const bool fifo_picked_up')
  } else { -1 }
  $finalResetSamplePosition = if ($finalFifoSamplePosition -ge 0) {
    $flushCompleteBody.IndexOf(
        'USB_SERIAL_JTAG_INTR_BUS_RESET', $finalFifoSamplePosition)
  } else { -1 }
  $finalElapsedSamplePosition = if ($finalResetSamplePosition -ge 0) {
    $flushCompleteBody.IndexOf(
        'const uint32_t completion_elapsed_ms', $finalResetSamplePosition)
  } else { -1 }
  $flushFinalSampleOrder =
      $finalFifoSamplePosition -ge 0 -and
      $finalResetSamplePosition -gt $finalFifoSamplePosition -and
      $finalElapsedSamplePosition -gt $finalResetSamplePosition
  $flushCompleteValid =
      $hasFlushCompleteDeclaration -and $null -ne $flushCompleteBody -and
      $flushCompleteBody -match 'tx_stash_len' -and
      $flushCompleteBody -match 'vRingbufferGetInfo' -and
      $flushCompleteBody -match
        'tx_loss_epoch\s*(?:==|!=)\s*expected_loss_epoch' -and
      $flushCompleteBody -match 'usb_serial_jtag_ll_txfifo_writable' -and
      ($flushCompleteBody -match 'usb_serial_jtag_ll_txfifo_flush' -or
       $flushCompleteBody -match 'hw_cdc_flush_txfifo_if_safe\s*\(') -and
      $flushCompleteBody -match 'USB_SERIAL_JTAG_INTR_BUS_RESET' -and
      $flushCompleteBody -match 'elapsed_ms\s*>=\s*timeout_ms' -and
      $flushFinalSampleOrder -and
      $flushCompleteBody -notmatch 'flushTXBuffer\s*\(\s*NULL'
  $checks.Add([pscustomobject][ordered]@{
      name='non_destructive_result_flush';valid=$flushCompleteValid
    })
  if (-not $flushCompleteValid) {
    Add-Failure ('HWCDC lacks a result-bearing, loss-epoch checked, ' +
        'ring+stash publication flush with a final timeout sample')
  }

  # For a future full-size or unknown final packet, the diagnostic terminal
  # ZLP remains a persistent transaction rather than a call-local flag.  The
  # current <=32-byte R19 path selects the short-packet policy and never enters
  # this branch. Macro-off retains the accepted call-local/per-loop behavior.
  $diagnosticMacro =
      '#if\s+defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' +
      '\s*&&\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS'
  $terminalStateDeclared =
      $hwcdcCode -match
        'enum\s+class\s+HwCdcR19TerminalZlpState[\s\S]*?None[\s\S]*?InFlight[\s\S]*?PickedUp' -and
      $hwcdcCode -match
        'static\s+volatile\s+HwCdcR19TerminalZlpState\s+tx_terminal_zlp_state' -and
      $hwcdcCode -match 'tx_terminal_zlp_loss_epoch' -and
      $hwcdcCode -match 'tx_terminal_zlp_publish_generation' -and
      $hwcdcCode -match 'tx_terminal_zlp_pickup_generation'
  $terminalDisablePosition = if ($null -ne $terminalZlpHelperBody) {
      $terminalZlpHelperBody.IndexOf('usb_serial_jtag_ll_disable_intr_mask')
    } else { -1 }
  $terminalClearPosition = if ($terminalDisablePosition -ge 0) {
      $terminalZlpHelperBody.IndexOf(
        'usb_serial_jtag_ll_clr_intsts_mask', $terminalDisablePosition)
    } else { -1 }
  $terminalBindPosition = if ($terminalClearPosition -ge 0) {
      $terminalZlpHelperBody.IndexOf(
        'tx_terminal_zlp_loss_epoch = tx_loss_epoch', $terminalClearPosition)
    } else { -1 }
  $terminalInFlightPosition = if ($terminalBindPosition -ge 0) {
      $terminalZlpHelperBody.IndexOf(
        'tx_terminal_zlp_state = HwCdcR19TerminalZlpState::InFlight',
        $terminalBindPosition)
    } else { -1 }
  $terminalEnablePosition = if ($terminalZlpHardwarePosition -ge 0) {
      $terminalZlpHelperBody.IndexOf(
        'usb_serial_jtag_ll_ena_intr_mask', $terminalZlpHardwarePosition)
    } else { -1 }
  $terminalPublishOrderValid =
      $terminalDisablePosition -ge 0 -and
      $terminalClearPosition -gt $terminalDisablePosition -and
      $terminalBindPosition -gt $terminalClearPosition -and
      $terminalInFlightPosition -gt $terminalBindPosition -and
      $terminalZlpRecordPosition -gt $terminalInFlightPosition -and
      $terminalZlpHardwarePosition -gt $terminalZlpRecordPosition -and
      $terminalEnablePosition -gt $terminalZlpHardwarePosition
  $flushRetryOwnershipValid =
      $null -ne $flushCompleteExecutable -and
      $terminalStateDeclared -and $terminalPublishOrderValid -and
      $flushCompleteExecutable -match 'record_flush_retry_attempt\s*\(' -and
      $flushCompleteExecutable -match
        'hw_cdc_r19_terminal_zlp_matches_locked\s*\(\s*expected_loss_epoch\s*\)' -and
      $flushCompleteExecutable -match
        ('if\s*\(\s*terminal_zlp_required\s*\)\s*\{[\s\S]*?' +
         'tx_terminal_zlp_state\s*==\s*' +
         'HwCdcR19TerminalZlpState::None[\s\S]*?' +
         'hw_cdc_r19_issue_terminal_zlp_locked\s*\(') -and
      $flushCompleteExecutable -match
        ('terminal_zlp_picked_up\s*=\s*!\s*terminal_zlp_required\s*\|\|' +
         '[\s\S]*?tx_terminal_zlp_state\s*==\s*' +
         'HwCdcR19TerminalZlpState::PickedUp[\s\S]*?' +
         'hw_cdc_r19_terminal_zlp_matches_locked')
  $macroOffFinalZlpPreserved =
      $null -ne $flushCompleteExecutable -and
      $flushCompleteExecutable -match
        ('#if\s*!defined\s*\(\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)' +
         '\s*\|\|\s*!VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*' +
         'bool\s+final_flush_issued\s*=\s*false\s*;') -and
      $flushCompleteExecutable -match
        ('#else\s*if\s*\(\s*!\s*final_flush_issued\s*\)\s*\{' +
         '[\s\S]*?final_flush_issued\s*=\s*' +
         'hw_cdc_flush_txfifo_if_safe\s*\(\s*\)') -and
      $flushCompleteExecutable -match
        ('if\s*\(\s*host_present\s*\)\s*\{\s*' +
         '#if\s+!\s*defined\s*\(\s*' +
         'VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*\)\s*\|\|\s*' +
         '!\s*VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\s*' +
         'hw_cdc_flush_txfifo_if_safe\s*\(\s*\)\s*;\s*' +
         '#endif\s*hw_cdc_enable_tx_intr\s*\(\s*\)\s*;\s*\}')
  $checks.Add([pscustomobject][ordered]@{
      name='terminal_zlp_ownership_survives_flush_reentry'
      expected=('full/unknown-policy terminal ZLP is bound/masked/cleared/' +
        'published/armed once per exact boundary, short policy bypasses it, ' +
        'and macro-off behavior remains unchanged')
      valid=($flushRetryOwnershipValid -and $macroOffFinalZlpPreserved)
    })
  if (-not ($flushRetryOwnershipValid -and $macroOffFinalZlpPreserved)) {
    Add-Failure ('terminal-ZLP ownership is not persistent across bounded ' +
        'flush calls, publication ordering is unsafe, or macro-off behavior changed')
  }

  $flushRetryRecordBody = Get-FunctionBody $diagnosticHeaderText `
      'record_flush_retry_attempt\s*\('
  $flushRetryRecordValid =
      $null -ne $flushRetryRecordBody -and
      $flushRetryRecordBody -match 'R19HwcdcFifoFlushOutcome::Timeout' -and
      $flushRetryRecordBody -match 'last_flush_task_zlp_count_\s*!=\s*1U' -and
      $flushRetryRecordBody -match 'last_flush_isr_zlp_count_\s*!=\s*0U' -and
      $flushRetryRecordBody -match 'state\.tx_loss_epoch\s*==\s*tx_loss_epoch_' -and
      $flushRetryRecordBody -match
        'state\.publish_generation\s*==\s*publish_generation_' -and
      $flushRetryRecordBody -match
        'state\.pickup_generation\s*==\s*pickup_generation_' -and
      $flushRetryRecordBody -notmatch
        'last_flush_task_zlp_count_\s*=\s*0U' -and
      $flushRetryRecordBody -notmatch
        'last_flush_isr_zlp_count_\s*=\s*0U'
  $checks.Add([pscustomobject][ordered]@{
      name='flush_retry_preserves_exact_terminal_zlp_accounting'
      valid=$flushRetryRecordValid
    })
  if (-not $flushRetryRecordValid) {
    Add-Failure ('flush retry can inherit a terminal ZLP without an exact ' +
        'timeout/epoch/generation/origin match, or resets its witness')
  }

  $staleInEmptyCannotAckTerminal =
      $null -ne $isrCode -and
      $isrCode -match
        'live_interrupt_status\s*=\s*usb_serial_jtag_ll_get_intsts_mask\s*\(\s*\)' -and
      $isrCode -match
        'live_in_empty_pending\s*=\s*[\s\S]*?USB_SERIAL_JTAG_INTR_SERIAL_IN_EMPTY' -and
      $isrCode -match
        'else\s+if\s*\(\s*!live_in_empty_pending\s*\)\s*\{\s*\}' -and
      $isrCode -match
        ('terminal_zlp_pickup_allowed[\s\S]*?' +
         'HwCdcR19TerminalZlpState::InFlight[\s\S]*?' +
         'tx_terminal_zlp_state\s*=\s*' +
         'HwCdcR19TerminalZlpState::PickedUp')
  $checks.Add([pscustomobject][ordered]@{
      name='stale_in_empty_snapshot_cannot_ack_terminal_zlp'
      valid=$staleInEmptyCannotAckTerminal
    })
  if (-not $staleInEmptyCannotAckTerminal) {
    Add-Failure ('ISR does not re-sample live IN_EMPTY under the TX mux or ' +
        'can let a stale entry snapshot acknowledge the terminal ZLP')
  }

  $terminalInvalidationCount = ([regex]::Matches(
      $hwcdcCode, 'hw_cdc_r19_invalidate_terminal_zlp_locked\s*\(')).Count
  $terminalPublicationInvalidations = ([regex]::Matches(
      $hwcdcCode,
      ('hw_cdc_r19_invalidate_terminal_zlp_locked\s*\(\s*\)\s*;' +
       '\s*tx_payload_publish_generation\s*=\s*' +
       'tx_payload_publish_generation\s*\+\s*1U'))).Count
  $terminalInvalidationCoverage =
      $terminalInvalidationCount -ge 10 -and
      $terminalPublicationInvalidations -ge 2 -and
      $null -ne $beginCode -and
      $beginCode -match 'hw_cdc_r19_invalidate_terminal_zlp_locked\s*\(' -and
      $null -ne $endCode -and
      $endCode -match 'hw_cdc_r19_invalidate_terminal_zlp_locked\s*\('
  $checks.Add([pscustomobject][ordered]@{
      name='terminal_zlp_invalidated_at_authoritative_boundaries'
      valid=$terminalInvalidationCoverage
    })
  if (-not $terminalInvalidationCoverage) {
    Add-Failure ('terminal-ZLP ownership is not invalidated by both payload ' +
        'publish sites and the begin/end/reset/discard/epoch boundaries')
  }

  $observationActiveDeclared =
      $hwcdcCode -match
        'static\s+volatile\s+bool\s+tx_r19_observation_active\s*=\s*false\s*;'
  $observationFlagGated =
      $hwcdcCode -match
        ('if\s*\(\s*tx_r19_observation_active\s*\)\s*\{[\s\S]*?' +
         'R19HwcdcFifoDiagnosticFlag::ObservationActive')
  $beginDisablePosition = if ($null -ne $beginCode) {
    $beginCode.IndexOf('usb_serial_jtag_ll_disable_intr_mask')
  } else { -1 }
  $beginAllocPosition = if ($null -ne $beginCode) {
    $beginCode.IndexOf('esp_intr_alloc')
  } else { -1 }
  $beginObservationStartPosition = if ($null -ne $beginCode) {
    $beginCode.IndexOf('tx_r19_observation_active = true')
  } else { -1 }
  $beginRecordInitializePosition = if ($null -ne $beginCode) {
    $beginCode.IndexOf(
        'vc_lora_r19_hwcdc_fifo_diagnostic_record.initialize')
  } else { -1 }
  $beginMaskEnablePosition = if ($null -ne $beginCode) {
    $beginCode.IndexOf('usb_serial_jtag_ll_ena_intr_mask')
  } else { -1 }
  $beginAllocFailureInvalidates =
      $null -ne $beginCode -and
      $beginCode -match
        ('esp_intr_alloc[\s\S]*?!=\s*ESP_OK\s*\)\s*\{' +
         '[\s\S]*?end\s*\(\s*\)\s*;[\s\S]*?return\s*;')
  $endResetsObservation =
      $null -ne $endCode -and
      $endCode -match 'tx_r19_observation_active\s*=\s*false\s*;' -and
      $endCode -match
        'vc_lora_r19_hwcdc_fifo_diagnostic_record\.reset\s*\(\s*\)'
  $observationBoundaryValid =
      $observationActiveDeclared -and $observationFlagGated -and
      $beginDisablePosition -ge 0 -and
      $beginAllocPosition -gt $beginDisablePosition -and
      $beginObservationStartPosition -gt $beginAllocPosition -and
      $beginRecordInitializePosition -gt $beginObservationStartPosition -and
      $beginMaskEnablePosition -gt $beginRecordInitializePosition -and
      $beginAllocFailureInvalidates -and $endResetsObservation
  $checks.Add([pscustomobject][ordered]@{
      name='diagnostic_observation_window_matches_isr_lifecycle'
      expected=('diagnostic masks stay disabled through ISR allocation; only ' +
        'successful install initializes an active record before mask enable; ' +
        'allocation failure and end invalidate the record')
      valid=$observationBoundaryValid
    })
  if (-not $observationBoundaryValid) {
    Add-Failure ('ObservationActive/record validity does not match the ' +
        'installed ISR observation window')
  }
} catch {
  Add-Failure $_.Exception.Message
} finally {
  $finishedUtc = (Get-Date).ToUniversalTime()
  $passed = $failures.Count -eq 0
  $summary = [ordered]@{
    schema_version=1;test=$testId
    result=if($passed){'PASS'}else{'FAIL'}
    started_utc=$startedUtc.ToString('o')
    finished_utc=$finishedUtc.ToString('o')
    fqbn=$Fqbn;expected_core_version=$ExpectedCoreVersion
    actual_core_version=$boardVersion;hwcdc_path=$hwcdcPath
    hwcdc_path_source=$hwcdcPathSource
    hwcdc_sha256=$hwcdcSha256;hwcdc_header_path=$hwcdcHeaderPath
    hwcdc_header_sha256=$hwcdcHeaderSha256
    diagnostic_header_path=$diagnosticHeaderPath
    diagnostic_header_sha256=$diagnosticHeaderSha256
    canonical_hwcdc_path=$canonicalHwcdcPath
    canonical_hwcdc_sha256=$canonicalHwcdcSha256
    canonical_hwcdc_header_path=$canonicalHwcdcHeaderPath
    canonical_hwcdc_header_sha256=$canonicalHwcdcHeaderSha256
    canonical_diagnostic_header_path=$canonicalDiagnosticHeaderPath
    canonical_diagnostic_header_sha256=$canonicalDiagnosticHeaderSha256
    checks=$checks.ToArray()
    failures=$failures.ToArray()
  }
  $summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8
  if ($passed) {
    Write-Host "PASS $testId core=$boardVersion HWCDC=$hwcdcSha256"
  }
}

if ($failures.Count -ne 0) { exit 1 }
