param(
  [string]$ArduinoCli,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedEsp32CoreVersion = '3.3.11',
  [string]$IdeConfig = (Join-Path $env:USERPROFILE `
    '.arduinoIDE\arduino-cli.yaml'),
  [string]$UpstreamCoreArchive = '',
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$canonicalRoot = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32'
$canonicalCpp = Join-Path $canonicalRoot 'HWCDC.cpp'
$canonicalHeader = Join-Path $canonicalRoot 'HWCDC.h'
$canonicalDiagnosticHeader = Join-Path $canonicalRoot `
  'HWCDCR19Diagnostic.h'
$baseCppSha256 =
  'C5ED5FDD05AA0DF9B74D390812643599223F96B459256718D0AD328AEABA6A8A'
$baseHeaderSha256 =
  '9A7D1672193E8F512DCDB020739771D85E98EAAEF090BD080564DDA0FBBF7022'
$priorCanonicalCppSha256 =
  '7D0781DCE611B8B322048B74EDE257561DEBD081E9D4204CE0C6153B951D34C3'
$priorCanonicalHeaderSha256 =
  '583CACD7ED221EFE53EC93BC2F2969B6332826BB9AC7197956139D2C810E33C3'
$intermediatePriorCanonicalCppSha256 =
  'BF704FF26CFA8D023C9EE08995C60CDFAC09F91E40E49F53D0239639937BC0E8'
$intermediatePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$immediatePriorCanonicalCppSha256 =
  'FDD06A57D8B99B20C9A1484E0257BDE82D06DCE97D3C001FA61CD3C71F7F2382'
$immediatePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$latestPriorCanonicalCppSha256 =
  'FEDBAB158836E9087A56005D6698E547971732741F1009E3F407E13C5B091261'
$latestPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$latestPriorCanonicalDiagnosticHeaderSha256 =
  '52C791294E1ADF926BF4A44017D9B8D11E7AC3F8D4693B27BEA9969BE712456F'
$immediatePriorThreeFileCanonicalCppSha256 =
  'F62E9D139A97A760DF582870BD9FA092D7E577D4F1F947967E7F9EB114EDD71F'
$immediatePriorThreeFileCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$immediatePriorThreeFileCanonicalDiagnosticHeaderSha256 =
  '52C791294E1ADF926BF4A44017D9B8D11E7AC3F8D4693B27BEA9969BE712456F'
$resetRacePriorCanonicalCppSha256 =
  '05FCACC3203F84EBA67491F6A15E8CE5CF98A6F6FDCCE71D9048E88C5E2EF05C'
$resetRacePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$resetRacePriorCanonicalDiagnosticHeaderSha256 =
  'D399038E73A86E42972C4216EE19C8CB105FF27C08BF5AFB8BCF3CA8C6B6E487'
$publishPendingPriorCanonicalCppSha256 =
  '9DF09A4FBB6A02CCA8882115E6AC657903875C642AF4AB6D56562011FF4FFCB0'
$publishPendingPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$publishPendingPriorCanonicalDiagnosticHeaderSha256 =
  'D399038E73A86E42972C4216EE19C8CB105FF27C08BF5AFB8BCF3CA8C6B6E487'
$payloadFlushPendingPriorCanonicalCppSha256 =
  '61F9751CDBE9E55F231E58BCF3D4A3F06F619C3B77F8D75E0627409222D98466'
$payloadFlushPendingPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$payloadFlushPendingPriorCanonicalDiagnosticHeaderSha256 =
  'FB4B753E27C81E92FBBE400AC7400B04CF3970FA838482753042FDE01FB3B600'
$diagnosticCompilePriorCanonicalCppSha256 =
  '61F9751CDBE9E55F231E58BCF3D4A3F06F619C3B77F8D75E0627409222D98466'
$diagnosticCompilePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$diagnosticCompilePriorCanonicalDiagnosticHeaderSha256 =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$isrZlpPriorCanonicalCppSha256 =
  '6CB63D54E63A4C0511878AAFDE8B914819E6C23BDD2D1F8852E5C1530DFF25B5'
$isrZlpPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$isrZlpPriorCanonicalDiagnosticHeaderSha256 =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$taskZlpPriorCanonicalCppSha256 =
  '5CF1835AE4DE0CD1CB2C3DE6AD0B8E25336690863A4E28354A9EBA8D4D8448F9'
$taskZlpPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$taskZlpPriorCanonicalDiagnosticHeaderSha256 =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$crossCallZlpPriorCanonicalCppSha256 =
  '1B9585EB7ECEA229ADDA060773B3C846489FB511CBE6E88AA9C01899ECA9907A'
$crossCallZlpPriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$crossCallZlpPriorCanonicalDiagnosticHeaderSha256 =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$runtimeStageCausePriorCanonicalCppSha256 =
  'CEF895A3CD6B649FF874649BF9118ADC8C40E774764D0DD8696DE531FAAA8D12'
$runtimeStageCausePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$runtimeStageCausePriorCanonicalDiagnosticHeaderSha256 =
  '4D10BF94D20DB0E864A3484FC005884C80CC809B6408DF37B3A603AEC461A1CF'
$busyIdlePriorCanonicalCppSha256 =
  '648DC44BEED5525890E728AC5215828B8CBE81E3C1C80E71FDD0D77935DC255D'
$busyIdlePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$busyIdlePriorCanonicalDiagnosticHeaderSha256 =
  'DE55AE69EF22D6EE6F8B4C01F4AF25663B62262E9C66D8BEDAB7C4033A262F60'
$flushCallEvidencePriorCanonicalCppSha256 =
  '286B9F38F4F9BE609939C99E01516BB2CFEBFC9094D182EF5DE04ED311A646D9'
$flushCallEvidencePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$flushCallEvidencePriorCanonicalDiagnosticHeaderSha256 =
  '7A2B74E59D2A26943FF760E00039754DF23C4EE6827DE5826C0933DBD1D0C958'

if (-not $ArduinoCli) {
  $ArduinoCli = Join-Path $env:TEMP `
    'arduino-cli-vc-lora-check\arduino-cli.exe'
}
if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
  $found = Get-Command arduino-cli -ErrorAction SilentlyContinue
  if (-not $found) { throw 'arduino-cli not found' }
  $ArduinoCli = $found.Source
}
foreach ($canonical in @(
    $canonicalCpp, $canonicalHeader, $canonicalDiagnosticHeader)) {
  if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
    throw "Canonical patched source not found: $canonical"
  }
}

$globalArgs = @()
if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
  $globalArgs += @('--config-file', $IdeConfig)
}
$board = (& $ArduinoCli @globalArgs board details --fqbn $Fqbn `
    --format json | ConvertFrom-Json)
if ([string]$board.version -cne $ExpectedEsp32CoreVersion) {
  throw "Expected ESP32 core $ExpectedEsp32CoreVersion, got $($board.version)"
}
$coreProperty = @($board.build_properties | Where-Object {
    $_ -like 'build.core.path=*'
  } | Select-Object -First 1)
if ($coreProperty.Count -ne 1) {
  throw 'Arduino board details did not expose build.core.path'
}
$corePath = ([string]$coreProperty[0]).Substring(
  ([string]$coreProperty[0]).IndexOf('=') + 1)
$installedCpp = Join-Path $corePath 'HWCDC.cpp'
$installedHeader = Join-Path $corePath 'HWCDC.h'
$installedDiagnosticHeader = Join-Path $corePath 'HWCDCR19Diagnostic.h'
foreach ($installed in @($installedCpp, $installedHeader)) {
  if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
    throw "Installed ESP32 core source not found: $installed"
  }
}
if ((Test-Path -LiteralPath $installedDiagnosticHeader) -and
    -not (Test-Path -LiteralPath $installedDiagnosticHeader -PathType Leaf)) {
  throw ('Installed HWCDC diagnostic-header path is not a file: ' +
    $installedDiagnosticHeader)
}

function Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-ExactPair([string]$ActualCpp, [string]$ActualHeader,
                        [string]$ExpectedCpp, [string]$ExpectedHeader) {
  return $ActualCpp -ceq $ExpectedCpp -and
    $ActualHeader -ceq $ExpectedHeader
}

# Classify only complete, exact source generations. In particular, a
# three-file generation is never downgraded to a two-file match when its
# diagnostic header is absent or from another generation.
function Get-InstalledSetKind(
    [string]$ActualCpp,
    [string]$ActualHeader,
    [bool]$DiagnosticExisted,
    [string]$ActualDiagnostic,
    [string]$CurrentCpp,
    [string]$CurrentHeader,
    [string]$CurrentDiagnostic) {
  if ($ActualCpp -ceq $CurrentCpp -and
      $ActualHeader -ceq $CurrentHeader -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq $CurrentDiagnostic) {
    return 'current-canonical'
  }
  if ($ActualCpp -ceq $flushCallEvidencePriorCanonicalCppSha256 -and
      $ActualHeader -ceq $flushCallEvidencePriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $flushCallEvidencePriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $busyIdlePriorCanonicalCppSha256 -and
      $ActualHeader -ceq $busyIdlePriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $busyIdlePriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $resetRacePriorCanonicalCppSha256 -and
      $ActualHeader -ceq $resetRacePriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $resetRacePriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $diagnosticCompilePriorCanonicalCppSha256 -and
      $ActualHeader -ceq $diagnosticCompilePriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $diagnosticCompilePriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $isrZlpPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $isrZlpPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $isrZlpPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $taskZlpPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $taskZlpPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $taskZlpPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $crossCallZlpPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $crossCallZlpPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $crossCallZlpPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $runtimeStageCausePriorCanonicalCppSha256 -and
      $ActualHeader -ceq $runtimeStageCausePriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $runtimeStageCausePriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $payloadFlushPendingPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $payloadFlushPendingPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $payloadFlushPendingPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $publishPendingPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $publishPendingPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $publishPendingPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $immediatePriorThreeFileCanonicalCppSha256 -and
      $ActualHeader -ceq $immediatePriorThreeFileCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $immediatePriorThreeFileCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if ($ActualCpp -ceq $latestPriorCanonicalCppSha256 -and
      $ActualHeader -ceq $latestPriorCanonicalHeaderSha256 -and
      $DiagnosticExisted -and
      $ActualDiagnostic -ceq
        $latestPriorCanonicalDiagnosticHeaderSha256) {
    return 'prior-canonical'
  }
  if (-not $DiagnosticExisted -and
      (($ActualCpp -ceq $immediatePriorCanonicalCppSha256 -and
        $ActualHeader -ceq $immediatePriorCanonicalHeaderSha256) -or
       ($ActualCpp -ceq $intermediatePriorCanonicalCppSha256 -and
        $ActualHeader -ceq $intermediatePriorCanonicalHeaderSha256) -or
       ($ActualCpp -ceq $priorCanonicalCppSha256 -and
        $ActualHeader -ceq $priorCanonicalHeaderSha256))) {
    return 'prior-canonical'
  }
  if (-not $DiagnosticExisted -and
      $ActualCpp -ceq $baseCppSha256 -and
      $ActualHeader -ceq $baseHeaderSha256) {
    return 'upstream'
  }
  return 'unknown-or-mixed'
}

function Assert-UpstreamBackupPair([string]$BackupCpp,
                                   [string]$BackupHeader) {
  if (-not (Test-Path -LiteralPath $BackupCpp -PathType Leaf) -or
      -not (Test-Path -LiteralPath $BackupHeader -PathType Leaf)) {
    throw ('Prior-canonical migration requires the complete recorded ' +
      'upstream HWCDC backup pair')
  }
  $backupCppHash = Sha256 $BackupCpp
  $backupHeaderHash = Sha256 $BackupHeader
  if (-not (Test-ExactPair $backupCppHash $backupHeaderHash `
      $baseCppSha256 $baseHeaderSha256)) {
    throw ('Recorded upstream HWCDC backup pair failed SHA-256 ' +
      "verification. Actual cpp=$backupCppHash header=$backupHeaderHash")
  }
}

function Save-ZipEntryDurable([IO.Compression.ZipArchiveEntry]$Entry,
                              [string]$Destination) {
  if ($Entry.Length -le 0 -or $Entry.Length -gt 1MB) {
    throw "Upstream HWCDC archive entry has an unsafe size: $($Entry.FullName)"
  }
  $input = $Entry.Open()
  try {
    $output = [IO.FileStream]::new(
      $Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
      [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
      $input.CopyTo($output)
      $output.Flush($true)
    } finally {
      $output.Dispose()
    }
  } finally {
    $input.Dispose()
  }
}

function Restore-UpstreamBackupPairFromArchive(
    [string]$BackupCpp, [string]$BackupHeader) {
  if ((Test-Path -LiteralPath $BackupCpp) -or
      (Test-Path -LiteralPath $BackupHeader)) {
    throw ('Refusing archive recovery over an existing or incomplete ' +
      'upstream HWCDC backup pair')
  }

  $archiveCandidate = $UpstreamCoreArchive
  if ([string]::IsNullOrWhiteSpace($archiveCandidate)) {
    $archiveCandidate = Join-Path $env:LOCALAPPDATA `
      "Arduino15\staging\packages\esp32-core-$ExpectedEsp32CoreVersion.zip"
  }
  if (-not (Test-Path -LiteralPath $archiveCandidate -PathType Leaf)) {
    throw ('Prior-canonical migration has no verified upstream backups and ' +
      "the exact core archive is unavailable: $archiveCandidate")
  }
  $archivePath = (Resolve-Path -LiteralPath $archiveCandidate).Path
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
  $nonce = [Guid]::NewGuid().ToString('N')
  $stageCpp = Join-Path $corePath ".HWCDC.cpp.vc_lora_upstream_$nonce"
  $stageHeader = Join-Path $corePath ".HWCDC.h.vc_lora_upstream_$nonce"
  $backupPublished = $false
  try {
    $cppEntries = @($archive.Entries | Where-Object {
        $_.FullName -cmatch '(?:^|/)cores/esp32/HWCDC\.cpp$'
      })
    $headerEntries = @($archive.Entries | Where-Object {
        $_.FullName -cmatch '(?:^|/)cores/esp32/HWCDC\.h$'
      })
    if ($cppEntries.Count -ne 1 -or $headerEntries.Count -ne 1) {
      throw ('Upstream ESP32 core archive must contain exactly one ' +
        'cores/esp32/HWCDC.cpp and HWCDC.h entry')
    }
    Save-ZipEntryDurable $cppEntries[0] $stageCpp
    Save-ZipEntryDurable $headerEntries[0] $stageHeader
    if (-not (Test-ExactPair (Sha256 $stageCpp) (Sha256 $stageHeader) `
        $baseCppSha256 $baseHeaderSha256)) {
      throw ('Upstream ESP32 core archive HWCDC pair failed the pinned ' +
        'base SHA-256 contract')
    }

    Move-Item -LiteralPath $stageCpp -Destination $BackupCpp
    try {
      Move-Item -LiteralPath $stageHeader -Destination $BackupHeader
    } catch {
      if (Test-Path -LiteralPath $BackupCpp -PathType Leaf) {
        Remove-Item -LiteralPath $BackupCpp -Force
      }
      throw
    }
    Assert-UpstreamBackupPair $BackupCpp $BackupHeader
    $backupPublished = $true
  } catch {
    if (-not $backupPublished) {
      foreach ($published in @($BackupCpp, $BackupHeader)) {
        if (Test-Path -LiteralPath $published -PathType Leaf) {
          Remove-Item -LiteralPath $published -Force
        }
      }
    }
    throw
  } finally {
    $archive.Dispose()
    foreach ($staged in @($stageCpp, $stageHeader)) {
      if (Test-Path -LiteralPath $staged -PathType Leaf) {
        Remove-Item -LiteralPath $staged -Force
      }
    }
  }
}

$canonicalCppHash = Sha256 $canonicalCpp
$canonicalHeaderHash = Sha256 $canonicalHeader
$canonicalDiagnosticHeaderHash = Sha256 $canonicalDiagnosticHeader
$installedCppHash = Sha256 $installedCpp
$installedHeaderHash = Sha256 $installedHeader
$installedDiagnosticExisted = Test-Path -LiteralPath `
  $installedDiagnosticHeader -PathType Leaf
$installedDiagnosticHeaderHash = if ($installedDiagnosticExisted) {
  Sha256 $installedDiagnosticHeader
} else {
  ''
}
$installedPairKind = Get-InstalledSetKind `
  -ActualCpp $installedCppHash `
  -ActualHeader $installedHeaderHash `
  -DiagnosticExisted $installedDiagnosticExisted `
  -ActualDiagnostic $installedDiagnosticHeaderHash `
  -CurrentCpp $canonicalCppHash `
  -CurrentHeader $canonicalHeaderHash `
  -CurrentDiagnostic $canonicalDiagnosticHeaderHash
if ($installedPairKind -ceq 'current-canonical') {
  Write-Output ('FW-HWCDC-PATCH-001 PASS already-installed ' +
    "cpp=$canonicalCppHash header=$canonicalHeaderHash " +
    "diagnostic_header=$canonicalDiagnosticHeaderHash")
  exit 0
}
if ($CheckOnly) {
  throw ('Installed HWCDC does not match the canonical VC LoRa patch. Run ' +
    '.\tools\install_patched_esp32_hwcdc.ps1 before compiling.')
}
if ($installedPairKind -ceq 'unknown-or-mixed') {
  $diagnosticDisplay = if ($installedDiagnosticExisted) {
    $installedDiagnosticHeaderHash
  } else {
    '<absent>'
  }
  throw ('Refusing to overwrite an unknown or mixed ESP32 3.3.11 HWCDC ' +
    'cpp/header/diagnostic-header generation. ' +
    "Actual cpp=$installedCppHash header=$installedHeaderHash " +
    "diagnostic_header=$diagnosticDisplay")
}

$backupCpp = Join-Path $corePath `
  "HWCDC.cpp.vc_lora_original_$baseCppSha256"
$backupHeader = Join-Path $corePath `
  "HWCDC.h.vc_lora_original_$baseHeaderSha256"
if ($installedPairKind -ceq 'prior-canonical') {
  # Never relabel a previously patched file as the original. Migration is
  # allowed only when the exact upstream pair was preserved by the earlier
  # installer generation.
  $backupCppExists = Test-Path -LiteralPath $backupCpp -PathType Leaf
  $backupHeaderExists = Test-Path -LiteralPath $backupHeader -PathType Leaf
  if ($backupCppExists -ne $backupHeaderExists) {
    throw 'Recorded upstream HWCDC backup pair is incomplete'
  }
  if ($backupCppExists) {
    Assert-UpstreamBackupPair $backupCpp $backupHeader
  } else {
    Restore-UpstreamBackupPairFromArchive $backupCpp $backupHeader
  }
} else {
  $backupCppExists = Test-Path -LiteralPath $backupCpp -PathType Leaf
  $backupHeaderExists = Test-Path -LiteralPath $backupHeader -PathType Leaf
  if ($backupCppExists -ne $backupHeaderExists) {
    throw 'Recorded upstream HWCDC backup pair is incomplete'
  }
  if ($backupCppExists) {
    Assert-UpstreamBackupPair $backupCpp $backupHeader
  } else {
    try {
      Copy-Item -LiteralPath $installedCpp -Destination $backupCpp
      Copy-Item -LiteralPath $installedHeader -Destination $backupHeader
      Assert-UpstreamBackupPair $backupCpp $backupHeader
    } catch {
      # These names are installer-owned and were absent before this attempt.
      # Remove a partial backup so a later run cannot mistake it for proof.
      foreach ($partial in @($backupCpp, $backupHeader)) {
        if (Test-Path -LiteralPath $partial -PathType Leaf) {
          Remove-Item -LiteralPath $partial -Force
        }
      }
      throw
    }
  }
}

# Stage the complete desired set and every pre-existing rollback file before
# replacing any installed member. Historical recognized generations contain
# only HWCDC.cpp/HWCDC.h, so rollback must also restore the diagnostic
# header's prior absence.
$nonce = [Guid]::NewGuid().ToString('N')
$stagedCpp = Join-Path $corePath ".HWCDC.cpp.vc_lora_stage_$nonce"
$stagedHeader = Join-Path $corePath ".HWCDC.h.vc_lora_stage_$nonce"
$stagedDiagnosticHeader = Join-Path $corePath `
  ".HWCDCR19Diagnostic.h.vc_lora_stage_$nonce"
$rollbackCpp = Join-Path $corePath ".HWCDC.cpp.vc_lora_rollback_$nonce"
$rollbackHeader = Join-Path $corePath ".HWCDC.h.vc_lora_rollback_$nonce"
$rollbackDiagnosticHeader = Join-Path $corePath `
  ".HWCDCR19Diagnostic.h.vc_lora_rollback_$nonce"
$replacementStarted = $false
try {
  Copy-Item -LiteralPath $canonicalCpp -Destination $stagedCpp
  Copy-Item -LiteralPath $canonicalHeader -Destination $stagedHeader
  Copy-Item -LiteralPath $canonicalDiagnosticHeader `
    -Destination $stagedDiagnosticHeader
  if (-not (Test-ExactPair (Sha256 $stagedCpp) (Sha256 $stagedHeader) `
        $canonicalCppHash $canonicalHeaderHash) -or
      (Sha256 $stagedDiagnosticHeader) -cne
        $canonicalDiagnosticHeaderHash) {
    throw 'Staged canonical HWCDC set failed SHA-256 verification'
  }
  Copy-Item -LiteralPath $installedCpp -Destination $rollbackCpp
  Copy-Item -LiteralPath $installedHeader -Destination $rollbackHeader
  if (-not (Test-ExactPair (Sha256 $rollbackCpp) (Sha256 $rollbackHeader) `
      $installedCppHash $installedHeaderHash)) {
    throw 'Staged HWCDC rollback pair failed SHA-256 verification'
  }
  if ($installedDiagnosticExisted) {
    Copy-Item -LiteralPath $installedDiagnosticHeader `
      -Destination $rollbackDiagnosticHeader
    if ((Sha256 $rollbackDiagnosticHeader) -cne
        $installedDiagnosticHeaderHash) {
      throw 'Staged HWCDC diagnostic-header rollback failed SHA-256 verification'
    }
  }

  $replacementStarted = $true
  Copy-Item -LiteralPath $stagedCpp -Destination $installedCpp -Force
  Copy-Item -LiteralPath $stagedHeader -Destination $installedHeader -Force
  Copy-Item -LiteralPath $stagedDiagnosticHeader `
    -Destination $installedDiagnosticHeader -Force
  if ([string]$env:VC_LORA_HWCDC_INSTALLER_TEST_FORCE_POST_REPLACE_FAILURE `
      -ceq '1') {
    throw 'forced post-replace failure'
  }
  $installedCppHashAfter = Sha256 $installedCpp
  $installedHeaderHashAfter = Sha256 $installedHeader
  $installedDiagnosticHeaderHashAfter = Sha256 $installedDiagnosticHeader
  if (-not (Test-ExactPair $installedCppHashAfter $installedHeaderHashAfter `
        $canonicalCppHash $canonicalHeaderHash) -or
      $installedDiagnosticHeaderHashAfter -cne
        $canonicalDiagnosticHeaderHash) {
    throw 'Patched HWCDC set verification failed after installation'
  }
  $installedCppHash = $installedCppHashAfter
  $installedHeaderHash = $installedHeaderHashAfter
  $installedDiagnosticHeaderHash = $installedDiagnosticHeaderHashAfter
} catch {
  $replacementFailure = $_
  if ($replacementStarted -and
      (Test-Path -LiteralPath $rollbackCpp -PathType Leaf) -and
      (Test-Path -LiteralPath $rollbackHeader -PathType Leaf)) {
    Copy-Item -LiteralPath $rollbackCpp -Destination $installedCpp -Force
    Copy-Item -LiteralPath $rollbackHeader -Destination $installedHeader -Force
    if ($installedDiagnosticExisted) {
      if (-not (Test-Path -LiteralPath $rollbackDiagnosticHeader `
          -PathType Leaf)) {
        throw ('HWCDC installation failed and diagnostic-header rollback ' +
          'material is missing: ' + $replacementFailure.Exception.Message)
      }
      Copy-Item -LiteralPath $rollbackDiagnosticHeader `
        -Destination $installedDiagnosticHeader -Force
    } elseif (Test-Path -LiteralPath $installedDiagnosticHeader) {
      Remove-Item -LiteralPath $installedDiagnosticHeader -Force
    }
    if (-not (Test-ExactPair (Sha256 $installedCpp) (Sha256 $installedHeader) `
          $installedCppHash $installedHeaderHash) -or
        ($installedDiagnosticExisted -and
          (Sha256 $installedDiagnosticHeader) -cne
            $installedDiagnosticHeaderHash) -or
        (-not $installedDiagnosticExisted -and
          (Test-Path -LiteralPath $installedDiagnosticHeader))) {
      throw ('HWCDC installation failed and exact set rollback also failed: ' +
        $replacementFailure.Exception.Message)
    }
  }
  throw $replacementFailure
} finally {
  foreach ($temporary in @(
      $stagedCpp, $stagedHeader, $stagedDiagnosticHeader,
      $rollbackCpp, $rollbackHeader, $rollbackDiagnosticHeader)) {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
  }
}
Write-Output ('FW-HWCDC-PATCH-001 PASS installed ' +
  "from=$installedPairKind cpp=$installedCppHash header=$installedHeaderHash " +
  "diagnostic_header=$installedDiagnosticHeaderHash")
