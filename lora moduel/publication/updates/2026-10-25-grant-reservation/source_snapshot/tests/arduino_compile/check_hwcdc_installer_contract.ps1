param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

# PowerShell 7 does not support Add-Type -OutputType ConsoleApplication on
# Windows.  This contract needs an executable fake arduino-cli, so re-enter it
# through the in-box Desktop host when CTest selected pwsh.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
  $desktopPowerShell = Join-Path $env:WINDIR `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $desktopPowerShell -PathType Leaf) {
    & $desktopPowerShell -NoLogo -NoProfile -NonInteractive `
      -ExecutionPolicy Bypass -File $PSCommandPath -RepoRoot $RepoRoot
    exit $LASTEXITCODE
  }
}

$ErrorActionPreference = 'Stop'
$testId = 'FW-HWCDC-INSTALLER-CONTRACT-001'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$installer = Join-Path $repo 'tools\install_patched_esp32_hwcdc.ps1'
$canonicalRoot = Join-Path $repo `
  'third_party\esp32-core-3.3.11-vc-lora\cores\esp32'
$canonicalDiagnosticHeader = Join-Path $canonicalRoot `
  'HWCDCR19Diagnostic.h'
$oldCppHash =
  '7D0781DCE611B8B322048B74EDE257561DEBD081E9D4204CE0C6153B951D34C3'
$oldHeaderHash =
  '583CACD7ED221EFE53EC93BC2F2969B6332826BB9AC7197956139D2C810E33C3'
$intermediatePriorCppHash =
  'BF704FF26CFA8D023C9EE08995C60CDFAC09F91E40E49F53D0239639937BC0E8'
$intermediatePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$immediatePriorCppHash =
  'FDD06A57D8B99B20C9A1484E0257BDE82D06DCE97D3C001FA61CD3C71F7F2382'
$immediatePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$latestPriorCppHash =
  'FEDBAB158836E9087A56005D6698E547971732741F1009E3F407E13C5B091261'
$latestPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$latestPriorDiagnosticHeaderHash =
  '52C791294E1ADF926BF4A44017D9B8D11E7AC3F8D4693B27BEA9969BE712456F'
$immediatePriorThreeFileCppHash =
  'F62E9D139A97A760DF582870BD9FA092D7E577D4F1F947967E7F9EB114EDD71F'
$immediatePriorThreeFileHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$immediatePriorThreeFileDiagnosticHeaderHash =
  '52C791294E1ADF926BF4A44017D9B8D11E7AC3F8D4693B27BEA9969BE712456F'
$resetRacePriorCppHash =
  '05FCACC3203F84EBA67491F6A15E8CE5CF98A6F6FDCCE71D9048E88C5E2EF05C'
$resetRacePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$resetRacePriorDiagnosticHeaderHash =
  'D399038E73A86E42972C4216EE19C8CB105FF27C08BF5AFB8BCF3CA8C6B6E487'
$publishPendingPriorCppHash =
  '9DF09A4FBB6A02CCA8882115E6AC657903875C642AF4AB6D56562011FF4FFCB0'
$publishPendingPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$publishPendingPriorDiagnosticHeaderHash =
  'D399038E73A86E42972C4216EE19C8CB105FF27C08BF5AFB8BCF3CA8C6B6E487'
$payloadFlushPendingPriorCppHash =
  '61F9751CDBE9E55F231E58BCF3D4A3F06F619C3B77F8D75E0627409222D98466'
$payloadFlushPendingPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$payloadFlushPendingPriorDiagnosticHeaderHash =
  'FB4B753E27C81E92FBBE400AC7400B04CF3970FA838482753042FDE01FB3B600'
$diagnosticCompilePriorCppHash =
  '61F9751CDBE9E55F231E58BCF3D4A3F06F619C3B77F8D75E0627409222D98466'
$diagnosticCompilePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$diagnosticCompilePriorDiagnosticHeaderHash =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$isrZlpPriorCppHash =
  '6CB63D54E63A4C0511878AAFDE8B914819E6C23BDD2D1F8852E5C1530DFF25B5'
$isrZlpPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$isrZlpPriorDiagnosticHeaderHash =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$taskZlpPriorCppHash =
  '5CF1835AE4DE0CD1CB2C3DE6AD0B8E25336690863A4E28354A9EBA8D4D8448F9'
$taskZlpPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$taskZlpPriorDiagnosticHeaderHash =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$crossCallZlpPriorCppHash =
  '1B9585EB7ECEA229ADDA060773B3C846489FB511CBE6E88AA9C01899ECA9907A'
$crossCallZlpPriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$crossCallZlpPriorDiagnosticHeaderHash =
  'BA68459A9AB712D00E06B9D4CD18B7B92CCDBDF140B2CEF8624BF71765AE8C0A'
$runtimeStageCausePriorCppHash =
  'CEF895A3CD6B649FF874649BF9118ADC8C40E774764D0DD8696DE531FAAA8D12'
$runtimeStageCausePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$runtimeStageCausePriorDiagnosticHeaderHash =
  '4D10BF94D20DB0E864A3484FC005884C80CC809B6408DF37B3A603AEC461A1CF'
$busyIdlePriorCanonicalCppSha256 =
  '648DC44BEED5525890E728AC5215828B8CBE81E3C1C80E71FDD0D77935DC255D'
$busyIdlePriorCanonicalHeaderSha256 =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$busyIdlePriorCanonicalDiagnosticHeaderSha256 =
  'DE55AE69EF22D6EE6F8B4C01F4AF25663B62262E9C66D8BEDAB7C4033A262F60'
$flushCallEvidencePriorCppHash =
  '286B9F38F4F9BE609939C99E01516BB2CFEBFC9094D182EF5DE04ED311A646D9'
$flushCallEvidencePriorHeaderHash =
  '1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC'
$flushCallEvidencePriorDiagnosticHeaderHash =
  '7A2B74E59D2A26943FF760E00039754DF23C4EE6827DE5826C0933DBD1D0C958'
$baseCppHash =
  'C5ED5FDD05AA0DF9B74D390812643599223F96B459256718D0AD328AEABA6A8A'
$baseHeaderHash =
  '9A7D1672193E8F512DCDB020739771D85E98EAAEF090BD080564DDA0FBBF7022'

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId $Message" }
}

function Write-FixtureText([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-TreeSnapshot([string]$Root) {
  $records = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File |
      Sort-Object FullName |
      ForEach-Object {
        [pscustomobject][ordered]@{
          path = $_.FullName.Substring($Root.Length).TrimStart('\')
          size = [int64]$_.Length
          sha256 = (Get-FileHash -LiteralPath $_.FullName `
            -Algorithm SHA256).Hash.ToUpperInvariant()
        }
      }
  )
  return ($records | ConvertTo-Json -Depth 4 -Compress)
}

Assert-Contract (Test-Path -LiteralPath $installer -PathType Leaf) `
  'installer is missing'
Assert-Contract (Test-Path -LiteralPath $canonicalDiagnosticHeader `
    -PathType Leaf) `
  'canonical HWCDC R19 diagnostic header is missing'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $installer, [ref]$tokens, [ref]$errors)
Assert-Contract (@($errors).Count -eq 0) 'installer has parser errors'
$source = Get-Content -LiteralPath $installer -Raw

foreach ($hash in @(
    $oldCppHash, $oldHeaderHash,
    $intermediatePriorCppHash, $intermediatePriorHeaderHash,
    $immediatePriorCppHash, $immediatePriorHeaderHash,
    $latestPriorCppHash, $latestPriorHeaderHash,
    $latestPriorDiagnosticHeaderHash,
    $immediatePriorThreeFileCppHash,
    $immediatePriorThreeFileHeaderHash,
    $immediatePriorThreeFileDiagnosticHeaderHash,
    $resetRacePriorCppHash,
    $resetRacePriorHeaderHash,
    $resetRacePriorDiagnosticHeaderHash,
    $payloadFlushPendingPriorCppHash,
    $payloadFlushPendingPriorHeaderHash,
    $payloadFlushPendingPriorDiagnosticHeaderHash,
    $diagnosticCompilePriorCppHash,
    $diagnosticCompilePriorHeaderHash,
    $diagnosticCompilePriorDiagnosticHeaderHash,
    $isrZlpPriorCppHash,
    $isrZlpPriorHeaderHash,
    $isrZlpPriorDiagnosticHeaderHash,
    $taskZlpPriorCppHash,
    $taskZlpPriorHeaderHash,
    $taskZlpPriorDiagnosticHeaderHash,
    $crossCallZlpPriorCppHash,
    $crossCallZlpPriorHeaderHash,
    $crossCallZlpPriorDiagnosticHeaderHash,
    $runtimeStageCausePriorCppHash,
    $runtimeStageCausePriorHeaderHash,
    $runtimeStageCausePriorDiagnosticHeaderHash,
    $flushCallEvidencePriorCppHash,
    $flushCallEvidencePriorHeaderHash,
    $flushCallEvidencePriorDiagnosticHeaderHash,
    $baseCppHash, $baseHeaderHash)) {
  Assert-Contract ($source.Contains($hash)) `
    "installer does not pin required migration hash $hash"
}
Assert-Contract ($source -match '\$installedPairKind\s*=') `
  'installer does not classify the installed cpp/header as one exact pair'
Assert-Contract ($source -match "'prior-canonical'") `
  'installer has no explicit prior-canonical migration path'
Assert-Contract ($source -match 'Assert-UpstreamBackupPair') `
  'installer does not verify the upstream backup pair'
Assert-Contract ($source -match 'Restore-UpstreamBackupPairFromArchive') `
  'installer cannot recover a missing upstream pair from the core archive'
Assert-Contract ($source -match
    'esp32-core-\$ExpectedEsp32CoreVersion\.zip') `
  'installer does not select the exact-version ESP32 staging archive'
Assert-Contract ($source -match
    'cores/esp32/HWCDC\\\.cpp\$' -and
    $source -match 'cores/esp32/HWCDC\\\.h\$') `
  'archive recovery does not select exact HWCDC entry suffixes'
Assert-Contract ($source -match 'baseCppSha256[\s\S]{0,200}?' +
    'baseHeaderSha256') `
  'archive recovery does not verify both pinned upstream hashes'
Assert-Contract ($source -notmatch 'ExtractToDirectory') `
  'installer unsafely extracts the complete core archive'
Assert-Contract ($source -match 'prior-canonical[\s\S]{0,3600}?' +
    '(?:Assert-UpstreamBackupPair|Restore-UpstreamBackupPairFromArchive)') `
  'prior-canonical migration is not conditioned on a verified/recovered backup pair'
Assert-Contract ($source -match 'Refusing to overwrite an unknown or mixed') `
  'installer does not explicitly reject mixed cpp/header generations'
Assert-Contract ($source -match 'rollback') `
  'installer does not retain a rollback path for a partial pair replacement'
Assert-Contract ($source -match 'HWCDCR19Diagnostic\.h') `
  'installer does not include the diagnostic header in the installed set'
Assert-Contract ($source -match 'installedDiagnosticExisted') `
  'installer does not preserve diagnostic-header absence for rollback'
Assert-Contract ($source -match
    'latestPriorCanonicalCppSha256[\s\S]{0,900}?' +
    'latestPriorCanonicalHeaderSha256[\s\S]{0,500}?' +
    'latestPriorCanonicalDiagnosticHeaderSha256') `
  'installer cannot migrate the exact latest three-file canonical generation'
Assert-Contract ($source -match
    'resetRacePriorCanonicalCppSha256[\s\S]{0,900}?' +
    'resetRacePriorCanonicalHeaderSha256[\s\S]{0,500}?' +
    'resetRacePriorCanonicalDiagnosticHeaderSha256') `
  'installer cannot migrate the exact pre-reset-race schema-2 generation'
Assert-Contract ($source -match
    'payloadFlushPendingPriorCanonicalCppSha256[\s\S]{0,900}?' +
    'payloadFlushPendingPriorCanonicalHeaderSha256[\s\S]{0,500}?' +
    'payloadFlushPendingPriorCanonicalDiagnosticHeaderSha256') `
  'installer cannot migrate the exact pre-payload-flush-witness schema-2 generation'
Assert-Contract ($source -match
    'isrZlpPriorCanonicalCppSha256[\s\S]{0,900}?' +
    'isrZlpPriorCanonicalHeaderSha256[\s\S]{0,500}?' +
    'isrZlpPriorCanonicalDiagnosticHeaderSha256') `
  'installer cannot migrate the exact pre-ISR-ZLP-liveness generation'
Assert-Contract ($source -match 'taskZlpPriorCanonicalCppSha256[\s\S]{0,900}?taskZlpPriorCanonicalHeaderSha256[\s\S]{0,500}?taskZlpPriorCanonicalDiagnosticHeaderSha256') 'installer cannot migrate the exact pre-task-ZLP-liveness generation'
Assert-Contract ($source -match 'crossCallZlpPriorCanonicalCppSha256[\s\S]{0,900}?crossCallZlpPriorCanonicalHeaderSha256[\s\S]{0,500}?crossCallZlpPriorCanonicalDiagnosticHeaderSha256') 'installer cannot migrate the exact pre-cross-call-ZLP-ownership generation'
Assert-Contract ($source -match 'runtimeStageCausePriorCanonicalCppSha256[\s\S]{0,900}?runtimeStageCausePriorCanonicalHeaderSha256[\s\S]{0,500}?runtimeStageCausePriorCanonicalDiagnosticHeaderSha256') 'installer cannot migrate the exact runtime-stage-cause generation'

# Exercise the installer's generation classifier with hash-only tuples.
# This keeps the regression deterministic even after the developer machine's
# installed Arduino core has itself migrated to the new canonical generation.
$classifierAsts = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-InstalledSetKind'
    }, $true))
Assert-Contract ($classifierAsts.Count -eq 1) `
  'installer does not expose exactly one installed-set classifier'
$immediatePriorThreeFileCanonicalCppSha256 =
  $immediatePriorThreeFileCppHash
$immediatePriorThreeFileCanonicalHeaderSha256 =
  $immediatePriorThreeFileHeaderHash
$immediatePriorThreeFileCanonicalDiagnosticHeaderSha256 =
  $immediatePriorThreeFileDiagnosticHeaderHash
$resetRacePriorCanonicalCppSha256 = $resetRacePriorCppHash
$resetRacePriorCanonicalHeaderSha256 = $resetRacePriorHeaderHash
$resetRacePriorCanonicalDiagnosticHeaderSha256 =
  $resetRacePriorDiagnosticHeaderHash
$latestPriorCanonicalCppSha256 = $latestPriorCppHash
$latestPriorCanonicalHeaderSha256 = $latestPriorHeaderHash
$latestPriorCanonicalDiagnosticHeaderSha256 =
  $latestPriorDiagnosticHeaderHash
$immediatePriorCanonicalCppSha256 = $immediatePriorCppHash
$immediatePriorCanonicalHeaderSha256 = $immediatePriorHeaderHash
$intermediatePriorCanonicalCppSha256 = $intermediatePriorCppHash
$intermediatePriorCanonicalHeaderSha256 = $intermediatePriorHeaderHash
$priorCanonicalCppSha256 = $oldCppHash
$priorCanonicalHeaderSha256 = $oldHeaderHash
$publishPendingPriorCanonicalCppSha256 = $publishPendingPriorCppHash
$publishPendingPriorCanonicalHeaderSha256 = $publishPendingPriorHeaderHash
$publishPendingPriorCanonicalDiagnosticHeaderSha256 =
  $publishPendingPriorDiagnosticHeaderHash
$payloadFlushPendingPriorCanonicalCppSha256 =
  $payloadFlushPendingPriorCppHash
$payloadFlushPendingPriorCanonicalHeaderSha256 =
  $payloadFlushPendingPriorHeaderHash
$payloadFlushPendingPriorCanonicalDiagnosticHeaderSha256 =
  $payloadFlushPendingPriorDiagnosticHeaderHash
$diagnosticCompilePriorCanonicalCppSha256 =
  $diagnosticCompilePriorCppHash
$diagnosticCompilePriorCanonicalHeaderSha256 =
  $diagnosticCompilePriorHeaderHash
$diagnosticCompilePriorCanonicalDiagnosticHeaderSha256 =
  $diagnosticCompilePriorDiagnosticHeaderHash
$isrZlpPriorCanonicalCppSha256 = $isrZlpPriorCppHash
$isrZlpPriorCanonicalHeaderSha256 = $isrZlpPriorHeaderHash
$isrZlpPriorCanonicalDiagnosticHeaderSha256 =
  $isrZlpPriorDiagnosticHeaderHash
$taskZlpPriorCanonicalCppSha256 = $taskZlpPriorCppHash
$taskZlpPriorCanonicalHeaderSha256 = $taskZlpPriorHeaderHash
$taskZlpPriorCanonicalDiagnosticHeaderSha256 =
  $taskZlpPriorDiagnosticHeaderHash
$crossCallZlpPriorCanonicalCppSha256 = $crossCallZlpPriorCppHash
$crossCallZlpPriorCanonicalHeaderSha256 = $crossCallZlpPriorHeaderHash
$crossCallZlpPriorCanonicalDiagnosticHeaderSha256 =
  $crossCallZlpPriorDiagnosticHeaderHash
$runtimeStageCausePriorCanonicalCppSha256 =
  $runtimeStageCausePriorCppHash
$runtimeStageCausePriorCanonicalHeaderSha256 =
  $runtimeStageCausePriorHeaderHash
$runtimeStageCausePriorCanonicalDiagnosticHeaderSha256 =
  $runtimeStageCausePriorDiagnosticHeaderHash
$flushCallEvidencePriorCanonicalCppSha256 = $flushCallEvidencePriorCppHash
$flushCallEvidencePriorCanonicalHeaderSha256 = $flushCallEvidencePriorHeaderHash
$flushCallEvidencePriorCanonicalDiagnosticHeaderSha256 =
  $flushCallEvidencePriorDiagnosticHeaderHash
$baseCppSha256 = $baseCppHash
$baseHeaderSha256 = $baseHeaderHash
Invoke-Expression $classifierAsts[0].Extent.Text

$canonicalCppHash = (Get-FileHash -LiteralPath `
    (Join-Path $canonicalRoot 'HWCDC.cpp') -Algorithm SHA256).Hash
$canonicalHeaderHash = (Get-FileHash -LiteralPath `
    (Join-Path $canonicalRoot 'HWCDC.h') -Algorithm SHA256).Hash
$canonicalDiagnosticHeaderHash = (Get-FileHash -LiteralPath `
    $canonicalDiagnosticHeader -Algorithm SHA256).Hash

function Classify-Fixture([string]$Cpp, [string]$Header,
                          [bool]$DiagnosticExisted,
                          [string]$Diagnostic) {
  return Get-InstalledSetKind `
    -ActualCpp $Cpp `
    -ActualHeader $Header `
    -DiagnosticExisted $DiagnosticExisted `
    -ActualDiagnostic $Diagnostic `
    -CurrentCpp $canonicalCppHash `
    -CurrentHeader $canonicalHeaderHash `
    -CurrentDiagnostic $canonicalDiagnosticHeaderHash
}

Assert-Contract ((Classify-Fixture $canonicalCppHash `
      $canonicalHeaderHash $true $canonicalDiagnosticHeaderHash) -ceq
    'current-canonical') `
  'classifier rejected the exact schema-2 current canonical set'
Assert-Contract ((Classify-Fixture $flushCallEvidencePriorCppHash `
      $flushCallEvidencePriorHeaderHash $true `
      $flushCallEvidencePriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-flush-call-evidence generation'
Assert-Contract ((Classify-Fixture $flushCallEvidencePriorCppHash `
      $flushCallEvidencePriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-flush-call-evidence set without its diagnostic header'
Assert-Contract ((Classify-Fixture $flushCallEvidencePriorCppHash `
      $flushCallEvidencePriorHeaderHash $true `
      $canonicalDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted old cpp/header with the new diagnostic header'
Assert-Contract ((Classify-Fixture $flushCallEvidencePriorCppHash `
      $canonicalHeaderHash $true `
      $flushCallEvidencePriorDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted the old cpp/diagnostic header with the new API header'
Assert-Contract ((Classify-Fixture $canonicalCppHash `
      $flushCallEvidencePriorHeaderHash $true `
      $flushCallEvidencePriorDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted the new cpp with the old header/diagnostic header'
Assert-Contract ((Classify-Fixture $busyIdlePriorCanonicalCppSha256 `
      $busyIdlePriorCanonicalHeaderSha256 $true `
      $busyIdlePriorCanonicalDiagnosticHeaderSha256) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-busy-idle-restart generation'
Assert-Contract ((Classify-Fixture $busyIdlePriorCanonicalCppSha256 `
      $busyIdlePriorCanonicalHeaderSha256 $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted pre-busy-idle files without their diagnostic header'
Assert-Contract ((Classify-Fixture $busyIdlePriorCanonicalCppSha256 `
      $busyIdlePriorCanonicalHeaderSha256 $true `
      $runtimeStageCausePriorDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted a mixed pre-busy-idle diagnostic header'
Assert-Contract ((Classify-Fixture $runtimeStageCausePriorCppHash `
      $busyIdlePriorCanonicalHeaderSha256 $true `
      $busyIdlePriorCanonicalDiagnosticHeaderSha256) -ceq 'unknown-or-mixed') `
  'classifier accepted a mixed pre-busy-idle cpp generation'
Assert-Contract ((Classify-Fixture $diagnosticCompilePriorCppHash `
      $diagnosticCompilePriorHeaderHash $true `
      $diagnosticCompilePriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the pre-diagnostic-compile-fix schema-2 generation'
Assert-Contract ((Classify-Fixture $diagnosticCompilePriorCppHash `
      $diagnosticCompilePriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-diagnostic-compile-fix set without its diagnostic header'
Assert-Contract ((Classify-Fixture $isrZlpPriorCppHash `
      $isrZlpPriorHeaderHash $true `
      $isrZlpPriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-ISR-ZLP-liveness schema-2 generation'
Assert-Contract ((Classify-Fixture $isrZlpPriorCppHash `
      $isrZlpPriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-ISR-ZLP-liveness set without its diagnostic header'
Assert-Contract ((Classify-Fixture $taskZlpPriorCppHash $taskZlpPriorHeaderHash $true $taskZlpPriorDiagnosticHeaderHash) -ceq 'prior-canonical') 'classifier cannot migrate the exact pre-task-ZLP-liveness schema-2 generation'
Assert-Contract ((Classify-Fixture $taskZlpPriorCppHash $taskZlpPriorHeaderHash $false '') -ceq 'unknown-or-mixed') 'classifier accepted the pre-task-ZLP-liveness set without its diagnostic header'
Assert-Contract ((Classify-Fixture $taskZlpPriorCppHash $taskZlpPriorHeaderHash $true $resetRacePriorDiagnosticHeaderHash) -ceq 'unknown-or-mixed') 'classifier accepted a mixed pre-task-ZLP-liveness diagnostic-header generation'
Assert-Contract ((Classify-Fixture $crossCallZlpPriorCppHash `
      $crossCallZlpPriorHeaderHash $true `
      $crossCallZlpPriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the pre-cross-call-ZLP-ownership generation'
Assert-Contract ((Classify-Fixture $crossCallZlpPriorCppHash `
      $crossCallZlpPriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted pre-cross-call-ZLP ownership without its diagnostic header'
Assert-Contract ((Classify-Fixture $crossCallZlpPriorCppHash `
      $crossCallZlpPriorHeaderHash $true $resetRacePriorDiagnosticHeaderHash) `
      -ceq 'unknown-or-mixed') `
  'classifier accepted a mixed pre-cross-call-ZLP diagnostic generation'
Assert-Contract ((Classify-Fixture $runtimeStageCausePriorCppHash `
      $runtimeStageCausePriorHeaderHash $true `
      $runtimeStageCausePriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact runtime-stage-cause generation'
Assert-Contract ((Classify-Fixture $runtimeStageCausePriorCppHash `
      $runtimeStageCausePriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the runtime-stage-cause set without its diagnostic header'
Assert-Contract ((Classify-Fixture $runtimeStageCausePriorCppHash `
      $runtimeStageCausePriorHeaderHash $true `
      $crossCallZlpPriorDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted a mixed runtime-stage-cause diagnostic generation'
Assert-Contract ((Classify-Fixture $publishPendingPriorCppHash `
      $publishPendingPriorHeaderHash $true `
      $publishPendingPriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-publish-witness schema-2 generation'
Assert-Contract ((Classify-Fixture $publishPendingPriorCppHash `
      $publishPendingPriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-publish-witness generation without its diagnostic header'
Assert-Contract ((Classify-Fixture $publishPendingPriorCppHash `
      $publishPendingPriorHeaderHash $true `
      $canonicalDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted a mixed pre-publish-witness/current diagnostic-header generation'
Assert-Contract ((Classify-Fixture $payloadFlushPendingPriorCppHash `
      $payloadFlushPendingPriorHeaderHash $true `
      $payloadFlushPendingPriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-payload-flush-witness schema-2 generation'
Assert-Contract ((Classify-Fixture $payloadFlushPendingPriorCppHash `
      $payloadFlushPendingPriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-payload-flush-witness generation without its diagnostic header'
Assert-Contract ((Classify-Fixture $resetRacePriorCppHash `
      $resetRacePriorHeaderHash $true `
      $resetRacePriorDiagnosticHeaderHash) -ceq 'prior-canonical') `
  'classifier cannot migrate the exact pre-reset-race schema-2 generation'
Assert-Contract ((Classify-Fixture $resetRacePriorCppHash `
      $resetRacePriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the pre-reset-race generation without its diagnostic header'
Assert-Contract ((Classify-Fixture $resetRacePriorCppHash `
      $resetRacePriorHeaderHash $true `
      $immediatePriorThreeFileDiagnosticHeaderHash) -ceq
    'unknown-or-mixed') `
  'classifier accepted a mixed pre-reset-race diagnostic-header generation'
Assert-Contract ((Classify-Fixture $immediatePriorThreeFileCppHash `
      $immediatePriorThreeFileHeaderHash $true `
      $immediatePriorThreeFileDiagnosticHeaderHash) -ceq
    'prior-canonical') `
  'classifier cannot migrate the exact immediate-prior F62E9D three-file set'
Assert-Contract ((Classify-Fixture $immediatePriorThreeFileCppHash `
      $immediatePriorThreeFileHeaderHash $false '') -ceq
    'unknown-or-mixed') `
  'classifier accepted the immediate-prior three-file set without its diagnostic header'
Assert-Contract ((Classify-Fixture $immediatePriorThreeFileCppHash `
      $immediatePriorThreeFileHeaderHash $true `
      $canonicalDiagnosticHeaderHash) -ceq 'unknown-or-mixed') `
  'classifier accepted an immediate-prior/current diagnostic-header mixture'
Assert-Contract ((Classify-Fixture $latestPriorCppHash `
      $latestPriorHeaderHash $true $latestPriorDiagnosticHeaderHash) -ceq
    'prior-canonical') `
  'classifier lost compatibility with the FEDBAB three-file generation'
Assert-Contract ((Classify-Fixture $latestPriorCppHash `
      $latestPriorHeaderHash $false '') -ceq 'unknown-or-mixed') `
  'classifier accepted the FEDBAB three-file generation without its diagnostic header'
Assert-Contract ((Classify-Fixture $oldCppHash $oldHeaderHash `
      $false '') -ceq 'prior-canonical') `
  'classifier lost compatibility with the historical two-file generation'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
  ('vc_lora_hwcdc_installer_contract_' + [Guid]::NewGuid().ToString('N'))
$fixturePrefix = Join-Path ([IO.Path]::GetTempPath()) `
  'vc_lora_hwcdc_installer_contract_'
$archiveRecoveryExercised = $false
$developerPriorThreeFileMigrationExercised = $false
$flushCallEvidencePriorMigrationExercised = $false
try {
  $corePath = Join-Path $fixtureRoot 'cores\esp32'
  New-Item -ItemType Directory -Path $corePath -Force | Out-Null
  $installedCpp = Join-Path $corePath 'HWCDC.cpp'
  $installedHeader = Join-Path $corePath 'HWCDC.h'
  $installedDiagnosticHeader = Join-Path $corePath `
    'HWCDCR19Diagnostic.h'
  Copy-Item -LiteralPath (Join-Path $canonicalRoot 'HWCDC.cpp') `
    -Destination $installedCpp
  Copy-Item -LiteralPath (Join-Path $canonicalRoot 'HWCDC.h') `
    -Destination $installedHeader
  Copy-Item -LiteralPath $canonicalDiagnosticHeader `
    -Destination $installedDiagnosticHeader

  $fakeCli = Join-Path $fixtureRoot 'fake-arduino-cli.exe'
  $fakeCliSource = @'
using System;

public static class FakeArduinoCli {
  public static int Main(string[] args) {
    string root = Environment.GetEnvironmentVariable(
      "VC_LORA_HWCDC_INSTALLER_FIXTURE_CORE");
    if (String.IsNullOrEmpty(root)) return 21;
    root = root.Replace("\\", "\\\\");
    Console.Write("{\"version\":\"3.3.11\",\"build_properties\":[" +
      "\"build.core.path=" + root + "\"]}");
    return 0;
  }
}
'@
  Add-Type -TypeDefinition $fakeCliSource -OutputAssembly $fakeCli `
    -OutputType ConsoleApplication
  $env:VC_LORA_HWCDC_INSTALLER_FIXTURE_CORE = $corePath

  $beforeCheckOnly = Get-TreeSnapshot $fixtureRoot
  $checkOutput = @(& $installer -ArduinoCli $fakeCli -IdeConfig '' `
    -CheckOnly)
  Assert-Contract (($checkOutput -join "`n") -match
      'FW-HWCDC-PATCH-001 PASS already-installed') `
    'CheckOnly rejected an exact current canonical pair'
  $afterCheckOnly = Get-TreeSnapshot $fixtureRoot
  Assert-Contract ($afterCheckOnly -ceq $beforeCheckOnly) `
    'CheckOnly changed the fixture core or created a backup/staging file'

  Write-FixtureText $installedHeader "unknown fixture header`n"
  $mixedBefore = Get-TreeSnapshot $fixtureRoot
  $mixedRejected = $false
  try {
    & $installer -ArduinoCli $fakeCli -IdeConfig '' | Out-Null
  } catch {
    $mixedRejected = $_.Exception.Message -match 'unknown or mixed'
  }
  Assert-Contract $mixedRejected `
    'installer did not reject a mixed current-cpp/unknown-header pair'
  Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $mixedBefore) `
    'mixed-pair rejection changed the fixture core'

  Write-FixtureText $installedCpp "unknown fixture cpp`n"
  Write-FixtureText $installedHeader "unknown fixture header`n"
  $unknownBefore = Get-TreeSnapshot $fixtureRoot
  $unknownRejected = $false
  try {
    & $installer -ArduinoCli $fakeCli -IdeConfig '' | Out-Null
  } catch {
    $unknownRejected = $_.Exception.Message -match 'unknown or mixed'
  }
  Assert-Contract $unknownRejected `
    'installer did not reject an unknown cpp/header pair'
  Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $unknownBefore) `
    'unknown-pair rejection changed the fixture core'

  # Recognized historical installations contain only HWCDC.cpp/HWCDC.h.
  # A stray third file must never be accepted as part of that generation.
  Remove-Item -LiteralPath $installedDiagnosticHeader -Force

  # Decode the repository-pinned fixture. It contains both the exact prior
  # canonical installed pair and the exact upstream archive entries, so this
  # migration test remains reproducible after the developer machine moves to
  # the new core and on clean CI workers.
  $migrationFixtureDir = Join-Path $repo `
    'tests\arduino_compile\fixtures'
  $migrationFixtureManifestPath = Join-Path $migrationFixtureDir `
    'hwcdc_3_3_11_migration_fixture.json'
  $migrationFixture = Get-Content -LiteralPath `
    $migrationFixtureManifestPath -Raw | ConvertFrom-Json
  Assert-Contract ([string]$migrationFixture.schema -ceq
      'vc-lora-hwcdc-migration-fixture-v1') `
    'migration fixture schema is invalid'
  $migrationFixtureBase64 = Join-Path $migrationFixtureDir `
    ([string]$migrationFixture.payload)
  $fixtureArchive = Join-Path $fixtureRoot 'hwcdc-migration-fixture.zip'
  [byte[]]$fixtureArchiveBytes = [Convert]::FromBase64String(
    (Get-Content -LiteralPath $migrationFixtureBase64 -Raw))
  Assert-Contract ($fixtureArchiveBytes.Length -eq
      [int64]$migrationFixture.decoded_size_bytes) `
    'decoded migration fixture size mismatch'
  [IO.File]::WriteAllBytes($fixtureArchive, $fixtureArchiveBytes)
  Assert-Contract ((Get-FileHash -LiteralPath $fixtureArchive `
      -Algorithm SHA256).Hash -ceq
        [string]$migrationFixture.decoded_sha256) `
    'decoded migration fixture SHA-256 mismatch'

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $fixtureZip = [IO.Compression.ZipFile]::OpenRead($fixtureArchive)
  try {
    $priorCppEntry = @($fixtureZip.Entries | Where-Object {
        $_.FullName -ceq 'prior-canonical/HWCDC.cpp'
      })
    $priorHeaderEntry = @($fixtureZip.Entries | Where-Object {
        $_.FullName -ceq 'prior-canonical/HWCDC.h'
      })
    Assert-Contract ($priorCppEntry.Count -eq 1 -and
        $priorHeaderEntry.Count -eq 1) `
      'migration fixture prior-canonical entry set is invalid'
    foreach ($row in @(
        @($priorCppEntry[0], $installedCpp),
        @($priorHeaderEntry[0], $installedHeader))) {
      $input = $row[0].Open()
      try {
        $output = [IO.File]::Open(
          $row[1], [IO.FileMode]::Create, [IO.FileAccess]::Write,
          [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose() }
      } finally { $input.Dispose() }
    }
  } finally {
    $fixtureZip.Dispose()
  }
  Assert-Contract ((Get-FileHash -LiteralPath $installedCpp `
      -Algorithm SHA256).Hash -ceq $oldCppHash -and
      (Get-FileHash -LiteralPath $installedHeader `
        -Algorithm SHA256).Hash -ceq $oldHeaderHash) `
    'repository fixture does not contain the exact prior-canonical pair'

  $priorBeforeCheck = Get-TreeSnapshot $fixtureRoot
  $priorCheckRejected = $false
  try {
    & $installer -ArduinoCli $fakeCli -IdeConfig '' `
      -UpstreamCoreArchive $fixtureArchive -CheckOnly | Out-Null
  } catch {
    $priorCheckRejected = $_.Exception.Message -match
      'does not match the canonical'
  }
  Assert-Contract $priorCheckRejected `
    'CheckOnly did not report that the exact prior pair needs migration'
  Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $priorBeforeCheck) `
    'CheckOnly recovered backups or otherwise changed the prior fixture'

  $migrationOutput = @(& $installer -ArduinoCli $fakeCli -IdeConfig '' `
    -UpstreamCoreArchive $fixtureArchive)
  Assert-Contract (($migrationOutput -join "`n") -match
      'FW-HWCDC-PATCH-001 PASS installed from=prior-canonical') `
    'exact prior-canonical archive migration did not pass'
  Assert-Contract ((Get-FileHash -LiteralPath $installedCpp `
      -Algorithm SHA256).Hash -ceq
        (Get-FileHash -LiteralPath (Join-Path $canonicalRoot 'HWCDC.cpp') `
          -Algorithm SHA256).Hash -and
      (Get-FileHash -LiteralPath $installedHeader `
        -Algorithm SHA256).Hash -ceq
        (Get-FileHash -LiteralPath (Join-Path $canonicalRoot 'HWCDC.h') `
          -Algorithm SHA256).Hash -and
      (Get-FileHash -LiteralPath $installedDiagnosticHeader `
        -Algorithm SHA256).Hash -ceq
        (Get-FileHash -LiteralPath $canonicalDiagnosticHeader `
          -Algorithm SHA256).Hash) `
    'archive migration did not install the current exact canonical set'
  $backupCpp = Join-Path $corePath `
    "HWCDC.cpp.vc_lora_original_$baseCppHash"
  $backupHeader = Join-Path $corePath `
    "HWCDC.h.vc_lora_original_$baseHeaderHash"
  Assert-Contract ((Get-FileHash -LiteralPath $backupCpp `
      -Algorithm SHA256).Hash -ceq $baseCppHash -and
      (Get-FileHash -LiteralPath $backupHeader `
        -Algorithm SHA256).Hash -ceq $baseHeaderHash) `
    'archive migration did not persist the exact upstream backup pair'

  # Recreate the recognized prior two-file state, inject a failure after the
  # three replacements, and prove rollback restores both old files and the
  # absence of the diagnostic header.
  $fixtureZip = [IO.Compression.ZipFile]::OpenRead($fixtureArchive)
  try {
    foreach ($row in @(
        @('prior-canonical/HWCDC.cpp', $installedCpp),
        @('prior-canonical/HWCDC.h', $installedHeader))) {
      $entry = @($fixtureZip.Entries | Where-Object {
          $_.FullName -ceq $row[0]
        })
      Assert-Contract ($entry.Count -eq 1) `
        "rollback fixture entry is invalid: $($row[0])"
      $input = $entry[0].Open()
      try {
        $output = [IO.File]::Open(
          $row[1], [IO.FileMode]::Create, [IO.FileAccess]::Write,
          [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose() }
      } finally { $input.Dispose() }
    }
  } finally {
    $fixtureZip.Dispose()
  }
  Remove-Item -LiteralPath $installedDiagnosticHeader -Force
  $rollbackBefore = Get-TreeSnapshot $fixtureRoot
  $env:VC_LORA_HWCDC_INSTALLER_TEST_FORCE_POST_REPLACE_FAILURE = '1'
  $rollbackFailureObserved = $false
  try {
    & $installer -ArduinoCli $fakeCli -IdeConfig '' `
      -UpstreamCoreArchive $fixtureArchive | Out-Null
  } catch {
    $rollbackFailureObserved = $_.Exception.Message -match `
      'forced post-replace failure'
  } finally {
    Remove-Item `
      Env:VC_LORA_HWCDC_INSTALLER_TEST_FORCE_POST_REPLACE_FAILURE `
      -ErrorAction SilentlyContinue
  }
  Assert-Contract $rollbackFailureObserved `
    'post-replace failure injection was not observed'
  Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $rollbackBefore) `
    'rollback did not restore the exact prior two-file state and header absence'

  # When the exact immediate-prior set is still installed on the development
  # machine, copy it read-only into the disposable fixture. Exercise both a
  # successful three-file migration and exact three-file rollback without
  # ever invoking the installer against the real Arduino core.
  $developerCore = Join-Path $env:LOCALAPPDATA `
    'Arduino15\packages\esp32\hardware\esp32\3.3.11\cores\esp32'
  $developerCpp = Join-Path $developerCore 'HWCDC.cpp'
  $developerHeader = Join-Path $developerCore 'HWCDC.h'
  $developerDiagnosticHeader = Join-Path $developerCore `
    'HWCDCR19Diagnostic.h'
  $developerSetAvailable = @(
    $developerCpp, $developerHeader, $developerDiagnosticHeader
  ) | ForEach-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
  }
  $developerCppHash = if (Test-Path -LiteralPath $developerCpp -PathType Leaf) {
    (Get-FileHash -LiteralPath $developerCpp -Algorithm SHA256).Hash
  } else { '' }
  $developerHeaderHash = if (Test-Path -LiteralPath $developerHeader -PathType Leaf) {
    (Get-FileHash -LiteralPath $developerHeader -Algorithm SHA256).Hash
  } else { '' }
  $developerDiagnosticHash = if (Test-Path -LiteralPath `
      $developerDiagnosticHeader -PathType Leaf) {
    (Get-FileHash -LiteralPath $developerDiagnosticHeader `
      -Algorithm SHA256).Hash
  } else { '' }
  $developerPriorKind = if (
      $developerCppHash -ceq $immediatePriorThreeFileCppHash -and
      $developerHeaderHash -ceq $immediatePriorThreeFileHeaderHash -and
      $developerDiagnosticHash -ceq
        $immediatePriorThreeFileDiagnosticHeaderHash) {
    'immediate-prior'
  } elseif (
      $developerCppHash -ceq $runtimeStageCausePriorCppHash -and
      $developerHeaderHash -ceq $runtimeStageCausePriorHeaderHash -and
      $developerDiagnosticHash -ceq
        $runtimeStageCausePriorDiagnosticHeaderHash) {
    'runtime-stage-cause-prior'
  } elseif (
      $developerCppHash -ceq $flushCallEvidencePriorCppHash -and
      $developerHeaderHash -ceq $flushCallEvidencePriorHeaderHash -and
      $developerDiagnosticHash -ceq
        $flushCallEvidencePriorDiagnosticHeaderHash) {
    'flush-call-evidence-prior'
  } else { '' }
  if (@($developerSetAvailable | Where-Object { -not $_ }).Count -eq 0 -and
      $developerPriorKind) {
    $developerSetBefore = @(
      (Get-FileHash -LiteralPath $developerCpp -Algorithm SHA256).Hash,
      (Get-FileHash -LiteralPath $developerHeader -Algorithm SHA256).Hash,
      (Get-FileHash -LiteralPath $developerDiagnosticHeader `
        -Algorithm SHA256).Hash
    ) -join '|'
    Copy-Item -LiteralPath $developerCpp -Destination $installedCpp -Force
    Copy-Item -LiteralPath $developerHeader -Destination $installedHeader -Force
    Copy-Item -LiteralPath $developerDiagnosticHeader `
      -Destination $installedDiagnosticHeader -Force

    if ($developerPriorKind -ceq 'flush-call-evidence-prior') {
      # Exercise this exact old three-file generation through the executable
      # fake CLI as well as the hash-only classifier. Rejections must not
      # recover backups, stage replacements, or mutate any fixture member.
      $oldTrioBeforeCheck = Get-TreeSnapshot $fixtureRoot
      $oldTrioCheckRejected = $false
      try {
        & $installer -ArduinoCli $fakeCli -IdeConfig '' `
          -UpstreamCoreArchive $fixtureArchive -CheckOnly | Out-Null
      } catch {
        $oldTrioCheckRejected = $_.Exception.Message -match
          'does not match the canonical'
      }
      Assert-Contract $oldTrioCheckRejected `
        'CheckOnly did not report that the pre-flush-call-evidence trio needs migration'
      Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $oldTrioBeforeCheck) `
        'CheckOnly mutated the exact pre-flush-call-evidence trio'

      Remove-Item -LiteralPath $installedDiagnosticHeader -Force
      $missingDiagnosticBefore = Get-TreeSnapshot $fixtureRoot
      $missingDiagnosticRejected = $false
      try {
        & $installer -ArduinoCli $fakeCli -IdeConfig '' `
          -UpstreamCoreArchive $fixtureArchive | Out-Null
      } catch {
        $missingDiagnosticRejected = $_.Exception.Message -match 'unknown or mixed'
      }
      Assert-Contract $missingDiagnosticRejected `
        'installer accepted the old trio without its required diagnostic header'
      Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $missingDiagnosticBefore) `
        'missing old diagnostic-header rejection mutated the fixture'
      Copy-Item -LiteralPath $developerDiagnosticHeader `
        -Destination $installedDiagnosticHeader

      Copy-Item -LiteralPath (Join-Path $canonicalRoot 'HWCDC.h') `
        -Destination $installedHeader -Force
      $mixedApiBefore = Get-TreeSnapshot $fixtureRoot
      $mixedApiRejected = $false
      try {
        & $installer -ArduinoCli $fakeCli -IdeConfig '' `
          -UpstreamCoreArchive $fixtureArchive | Out-Null
      } catch {
        $mixedApiRejected = $_.Exception.Message -match 'unknown or mixed'
      }
      Assert-Contract $mixedApiRejected `
        'installer accepted the old cpp/diagnostic header with the new API header'
      Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq $mixedApiBefore) `
        'mixed old/new API-header rejection mutated the fixture'
      Copy-Item -LiteralPath $developerHeader -Destination $installedHeader -Force
    }

    $threeFileMigrationOutput = @(& $installer -ArduinoCli $fakeCli `
      -IdeConfig '' -UpstreamCoreArchive $fixtureArchive)
    Assert-Contract (($threeFileMigrationOutput -join "`n") -match
        'FW-HWCDC-PATCH-001 PASS installed from=prior-canonical') `
      "exact $developerPriorKind three-file migration did not pass"
    Assert-Contract ((Get-FileHash -LiteralPath $installedCpp `
          -Algorithm SHA256).Hash -ceq $canonicalCppHash -and
        (Get-FileHash -LiteralPath $installedHeader `
          -Algorithm SHA256).Hash -ceq $canonicalHeaderHash -and
        (Get-FileHash -LiteralPath $installedDiagnosticHeader `
          -Algorithm SHA256).Hash -ceq $canonicalDiagnosticHeaderHash) `
      "$developerPriorKind migration did not install the exact schema-2 canonical set"

    Copy-Item -LiteralPath $developerCpp -Destination $installedCpp -Force
    Copy-Item -LiteralPath $developerHeader -Destination $installedHeader -Force
    Copy-Item -LiteralPath $developerDiagnosticHeader `
      -Destination $installedDiagnosticHeader -Force
    $threeFileRollbackBefore = Get-TreeSnapshot $fixtureRoot
    $env:VC_LORA_HWCDC_INSTALLER_TEST_FORCE_POST_REPLACE_FAILURE = '1'
    $threeFileRollbackFailureObserved = $false
    try {
      & $installer -ArduinoCli $fakeCli -IdeConfig '' `
        -UpstreamCoreArchive $fixtureArchive | Out-Null
    } catch {
      $threeFileRollbackFailureObserved = $_.Exception.Message -match `
        'forced post-replace failure'
    } finally {
      Remove-Item `
        Env:VC_LORA_HWCDC_INSTALLER_TEST_FORCE_POST_REPLACE_FAILURE `
        -ErrorAction SilentlyContinue
    }
    Assert-Contract $threeFileRollbackFailureObserved `
      'three-file post-replace failure injection was not observed'
    Assert-Contract ((Get-TreeSnapshot $fixtureRoot) -ceq
        $threeFileRollbackBefore) `
      "rollback did not restore the exact $developerPriorKind three-file state"

    $developerSetAfter = @(
      (Get-FileHash -LiteralPath $developerCpp -Algorithm SHA256).Hash,
      (Get-FileHash -LiteralPath $developerHeader -Algorithm SHA256).Hash,
      (Get-FileHash -LiteralPath $developerDiagnosticHeader `
        -Algorithm SHA256).Hash
    ) -join '|'
    Assert-Contract ($developerSetAfter -ceq $developerSetBefore) `
      'the installed Arduino core changed during disposable-fixture testing'
    $developerPriorThreeFileMigrationExercised = $true
    $flushCallEvidencePriorMigrationExercised =
      $developerPriorKind -ceq 'flush-call-evidence-prior'
  }
  $archiveRecoveryExercised = $true
} finally {
  Remove-Item Env:VC_LORA_HWCDC_INSTALLER_FIXTURE_CORE `
    -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
    Assert-Contract ($resolvedFixture.StartsWith(
        $fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) `
      "refusing to delete unsafe fixture path: $resolvedFixture"
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}

Write-Output ("$testId PASS check_only_unchanged=true mixed_rejected=true " +
  "unknown_rejected=true archive_recovery_exercised=$archiveRecoveryExercised " +
  ('developer_prior_three_file_migration_exercised=' +
    $developerPriorThreeFileMigrationExercised) +
  (' pre_flush_call_evidence_migration_and_rollback_exercised=' +
    $flushCallEvidencePriorMigrationExercised))
