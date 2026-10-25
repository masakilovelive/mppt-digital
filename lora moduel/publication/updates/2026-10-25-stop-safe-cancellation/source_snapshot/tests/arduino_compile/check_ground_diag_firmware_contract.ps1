param(
  [string]$ArduinoCli = 'C:\resources\app\lib\backend\resources\arduino-cli.exe',
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$IdeConfig = (Join-Path $env:USERPROFILE '.arduinoIDE\arduino-cli.yaml'),
  [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-GROUND-DIAG-001'
$expectedVehicleTreeSha256 =
  '2A2A6FFEED518F67107C304D232299F853072CF1113733EC359EC8FC93768D09'
$expectedGroundTreeSha256 =
  '5F6E0AE1A7C736022D3D19E19B7E4BA1F44A8D9DC1BE56BC7F1829F16C5F31BD'

function Require-Text {
  param([string]$Path, [string]$Pattern, [string]$Description)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$testId`: missing $Description at $Path"
  }
  if ((Get-Content -Raw -LiteralPath $Path) -notmatch $Pattern) {
    throw "$testId`: $Description does not satisfy /$Pattern/"
  }
}

function Reject-Text {
  param([string]$Path, [string]$Pattern, [string]$Description)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$testId`: missing $Description at $Path"
  }
  if ((Get-Content -Raw -LiteralPath $Path) -match $Pattern) {
    throw "$testId`: $Description unexpectedly matches /$Pattern/"
  }
}

function Require-SameFile {
  param([string]$Expected, [string]$Actual, [string]$Description)
  if (-not (Test-Path -LiteralPath $Expected -PathType Leaf) -or
      -not (Test-Path -LiteralPath $Actual -PathType Leaf)) {
    throw "$testId`: missing $Description"
  }
  $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Expected).Hash
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Actual).Hash
  if ($expectedHash -ne $actualHash) {
    throw "$testId`: $Description differs from its canonical source"
  }
}

function Require-SameNameSet {
  param([string[]]$Expected, [string[]]$Actual, [string]$Description)
  $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) `
      -DifferenceObject @($Actual | Sort-Object))
  if ($difference.Count -ne 0) {
    $details = ($difference | ForEach-Object {
        "$($_.SideIndicator)$($_.InputObject)"
      }) -join ', '
    throw "$testId`: $Description differs: $details"
  }
}

function Get-TreeSha256 {
  param([string]$Path)
  $root = (Resolve-Path -LiteralPath $Path).Path
  $packageFiles = @(
    Get-ChildItem -LiteralPath $root -File |
      Where-Object { $_.Extension -in @('.ino', '.h', '.hpp', '.cpp') }
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Filter '*.cpp'
    Get-ChildItem -LiteralPath (Join-Path $root 'vc_lora') -File -Filter '*.hpp'
  )
  $manifestLines = @($packageFiles | ForEach-Object {
      $relative = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
      $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
      "$relative`t$fileHash"
    } | Sort-Object)
  $bytes = [Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Require-ProductionTreesUnchanged {
  $vehicleHash = Get-TreeSha256 (Join-Path $RepoRoot 'vc_lora_vehicle_xiao_esp32s3')
  $groundHash = Get-TreeSha256 (Join-Path $RepoRoot 'vc_lora_ground_xiao_esp32s3')
  if ($vehicleHash -ne $expectedVehicleTreeSha256) {
    throw "$testId`: production Vehicle tree changed: $vehicleHash"
  }
  if ($groundHash -ne $expectedGroundTreeSha256) {
    throw "$testId`: production Ground tree changed: $groundHash"
  }
}

function Get-AdapterWithoutDiagnosticBlocks {
  param([string]$Text)
  $kept = New-Object System.Collections.Generic.List[string]
  $diagnosticDepth = 0
  foreach ($line in ($Text -split "`r?`n")) {
    if ($diagnosticDepth -eq 0 -and $line -match
        '^\s*#\s*if\s+defined\s*\(\s*VC_LORA_PHASE6_GROUND_DIAGNOSTICS\s*\)') {
      $diagnosticDepth = 1
      continue
    }
    if ($diagnosticDepth -gt 0) {
      if ($line -match '^\s*#\s*(?:if|ifdef|ifndef)\b') {
        ++$diagnosticDepth
      } elseif ($line -match '^\s*#\s*endif\b') {
        --$diagnosticDepth
      }
      continue
    }
    if ($line.Trim().Length -gt 0) {
      $kept.Add($line.TrimEnd())
    }
  }
  if ($diagnosticDepth -ne 0) {
    throw "$testId`: unterminated diagnostics-only adapter block"
  }
  return ($kept -join "`n")
}

Require-ProductionTreesUnchanged

$diagRoot = Join-Path $RepoRoot 'vc_lora_ground_diag_xiao_esp32s3'
$diagSketch = Join-Path $diagRoot 'vc_lora_ground_diag_xiao_esp32s3.ino'
$diagHeader = Join-Path $diagRoot 'vc_lora_ground_diag.hpp'
$diagObserver = Join-Path $diagRoot 'vc_lora_ground_diag_observer.hpp'
$diagAdapter = Join-Path $diagRoot 'vc_lora_phase6_bridge.hpp'
$canonicalAdapter = Join-Path $RepoRoot 'firmware\phase6\vc_lora_phase6_bridge.hpp'
$canonicalUmbrella = Join-Path $RepoRoot `
  'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h'
$diagUmbrella = Join-Path $diagRoot 'VC_LoRa_Core.h'
$queryTool = Join-Path $RepoRoot 'tools\ground_diag_query.ps1'

Require-Text $diagSketch '#\s*define\s+VC_LORA_PHASE6_GROUND\s+1(?:\s|$)' `
  'Ground role macro'
Require-Text $diagSketch `
  '#\s*define\s+VC_LORA_PHASE6_GROUND_DIAGNOSTICS\s+1(?:\s|$)' `
  'Ground-only diagnostics macro'
Reject-Text $diagSketch 'VC_LORA_PHASE6_GROUND_USB_BPS' `
  'Ground diagnostic USB baud override'
Reject-Text $diagSketch '#\s*define\s+VC_LORA_PHASE6_VEHICLE\b' `
  'diagnostic sketch Vehicle role purity'
foreach ($include in @('VC_LoRa_Core.h', 'vc_lora_ground_diag_observer.hpp',
    'vc_lora_phase6_bridge.hpp', 'vc_lora_ground_diag.hpp')) {
  Require-Text $diagSketch `
    ("#\s*include\s*[`"<]{0}[`">]" -f [regex]::Escape($include)) `
    "sketch-local include $include"
}

foreach ($productionSketch in @(
    (Join-Path $RepoRoot 'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino'),
    (Join-Path $RepoRoot 'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'))) {
  Reject-Text $productionSketch 'VC_LORA_PHASE6_GROUND_DIAGNOSTICS|vc_lora_ground_diag' `
    'production sketch diagnostic purity'
  Reject-Text $productionSketch 'VC_LORA_PHASE6_GROUND_USB_BPS' `
    'production sketch Ground USB diagnostic override purity'
}

Require-Text $diagAdapter `
  'static_assert\s*\(\s*kTddProtocolVersion\s*==\s*3U\s*&&\s*kTddControlFrameSize\s*==\s*32U' `
  'protocol v3 exact-32 compile contract'
Require-Text $diagHeader 'VC_LORA_PHASE6_GROUND_DIAGNOSTICS' `
  'diagnostic compile guard'
Require-Text $diagHeader 'kQuery\s*\[\s*\]\s*=\s*"VCGSTAT\?\\n"' `
  'exact fixed ASCII query'
foreach ($tag in @('GCSTAT1', 'GCSTAT2', 'GCSTAT3')) {
  Require-Text $diagHeader ([regex]::Escape($tag)) "$tag response"
  Require-Text $queryTool ([regex]::Escape($tag)) "$tag query-tool contract"
}
Require-Text $diagHeader 'Serial\s*\.\s*availableForWrite\s*\(' `
  'non-blocking USB output backpressure'
Require-Text $diagHeader `
  'GroundTddState::WaitGrant[\s\S]{0,350}!\s*radio_busy[\s\S]{0,250}!\s*pending_radio_action\.active' `
  'radio-idle WaitGrant formatting safe point'
Reject-Text $diagHeader `
  '(?:e220_serial|Serial1|Serial2)\s*\.\s*(?:write|print|println|printf)\s*\(' `
  'diagnostic non-USB transport output'
Reject-Text $diagHeader `
  '\b(?:delay|delayMicroseconds)\s*\(|\bString\b|\bmalloc\s*\(|\bnew\s+' `
  'blocking or dynamic-allocation diagnostic path'
Reject-Text $diagObserver `
  '(?:e220_serial|Serial|Serial1|Serial2)\s*\.\s*(?:write|print|println|printf)\s*\(' `
  'observer transport-output purity'
Reject-Text $diagObserver '\b(?:String|malloc|calloc|realloc|free)\b|\bnew\s+' `
  'observer dynamic-allocation purity'

foreach ($hook in @('route_usb_byte', 'flush_query_candidate',
    'observe_usb_ingress', 'observe_e220_raw',
    'observe_radio_control_before', 'observe_radio_control_after',
    'observe_action_issued', 'observe_ground_controller')) {
  Require-Text $diagObserver ("\b{0}\s*\(" -f $hook) "$hook implementation"
  Require-Text $diagAdapter ("\b{0}\s*\(" -f $hook) "$hook adapter hook"
}
foreach ($state in @('WaitGrant', 'UplinkGuard', 'UplinkSend',
    'UplinkDrain', 'SendUlDone', 'DoneDrain')) {
  Require-Text $diagObserver ("GroundTddState::{0}" -f $state) `
    "Ground state histogram $state"
}
foreach ($field in @('gr', 'dup', 'fut', 'stcy', 'stss', 'utx', 'upb',
    'itx', 'dtx', 'ar', 'ex', 'ins', 'ubi', 'uvf', 'u20', 'uqf',
    'udf', 'raw', 'ctl', 'aux', 'rb', 'fail', 'st', 'sid', 'cy')) {
  Require-Text $diagHeader ("\b{0}=%" -f $field) "report field $field"
}
Require-Text $diagHeader `
  'query_request_pending[\s\S]{0,500}pending_snapshot\s*=\s*capture_snapshot\s*\(\s*\)' `
  'query-triggered POD snapshot'
Require-Text $diagHeader `
  'static_cast<unsigned long>\s*\(\s*s\.query_id\s*\)' `
  'correlated query sequence'

$diagAdapterText = Get-Content -Raw -LiteralPath $diagAdapter
$canonicalAdapterText = Get-Content -Raw -LiteralPath $canonicalAdapter
$diagnosticBlockMatches = [regex]::Matches(
  $diagAdapterText,
  '(?ms)^\s*#\s*if\s+defined\s*\(\s*VC_LORA_PHASE6_GROUND_DIAGNOSTICS\s*\)\s*$' +
  '(?<body>.*?)^\s*#\s*endif\b[^\r\n]*$')
if ($diagnosticBlockMatches.Count -eq 0) {
  throw "$testId`: diagnostic adapter has no guarded hook blocks"
}
$strippedDiagAdapter = Get-AdapterWithoutDiagnosticBlocks $diagAdapterText
$strippedCanonicalAdapter = Get-AdapterWithoutDiagnosticBlocks $canonicalAdapterText
if ($strippedDiagAdapter -cne $strippedCanonicalAdapter) {
  throw "$testId`: diagnostic adapter changes exist outside guarded blocks"
}

Require-Text $queryTool '\[string\]\s*\$Port\s*=\s*''COM6''' `
  'Ground diagnostic COM default'
Require-Text $queryTool '\[int\]\s*\$Baud\s*=\s*57600' `
  'Ground diagnostic USB baud default'
Require-Text $queryTool 'GetBytes\s*\(\s*"VCGSTAT\?`n"\s*\)' `
  'query tool exact fixed request'
Require-Text $queryTool 'DtrEnable\s*=\s*\$false' 'DTR disabled'
Require-Text $queryTool 'RtsEnable\s*=\s*\$false' 'RTS disabled'
Reject-Text $diagAdapter 'VC_LORA_PHASE6_GROUND_USB_BPS' `
  'Ground diagnostic USB baud override'
& $queryTool -SelfTest
if (-not $?) { throw "$testId`: query-tool self-test failed" }

Require-SameFile $canonicalUmbrella $diagUmbrella `
  'diagnostic sketch-local core umbrella'
$coreSources = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'core\src') `
  -File -Filter '*.cpp')
$coreHeaders = @(Get-ChildItem -LiteralPath `
  (Join-Path $RepoRoot 'core\include\vc_lora') -File -Filter '*.hpp')
foreach ($source in $coreSources) {
  Require-SameFile $source.FullName (Join-Path $diagRoot "src\$($source.Name)") `
    "diagnostic source $($source.Name)"
}
foreach ($header in $coreHeaders) {
  Require-SameFile $header.FullName (Join-Path $diagRoot "vc_lora\$($header.Name)") `
    "diagnostic header $($header.Name)"
}
Require-SameNameSet @($coreSources.Name) `
  @(Get-ChildItem (Join-Path $diagRoot 'src') -File -Filter '*.cpp' |
      ForEach-Object Name) 'diagnostic source basename set'
Require-SameNameSet @($coreHeaders.Name) `
  @(Get-ChildItem (Join-Path $diagRoot 'vc_lora') -File -Filter '*.hpp' |
      ForEach-Object Name) 'diagnostic header basename set'

if (-not $SkipCompile) {
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    throw "$testId`: Arduino IDE bundled CLI not found at $ArduinoCli"
  }
  $cliVersion = (& $ArduinoCli version --format json | ConvertFrom-Json)
  if ($cliVersion.VersionString -ne '1.3.1') {
    throw "$testId`: expected CLI 1.3.1, got $($cliVersion.VersionString)"
  }
  $globalArgs = @()
  if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
    $globalArgs += @('--config-file', $IdeConfig)
  }
  $board = (& $ArduinoCli @globalArgs board details --fqbn $Fqbn `
    --format json | ConvertFrom-Json)
  if ($board.version -ne '3.3.6') {
    throw "$testId`: expected ESP32 core 3.3.6, got $($board.version)"
  }
  $buildPath = Join-Path $env:TEMP "vc_lora_ground_diag_$PID"
  $compileOutput = @(& $ArduinoCli @globalArgs compile --fqbn $Fqbn `
    --warnings all --clean --build-path $buildPath --json $diagRoot 2>&1)
  $compileExit = $LASTEXITCODE
  $compileResult = (($compileOutput -join "`n") | ConvertFrom-Json)
  if ($compileExit -ne 0 -or -not $compileResult.success) {
    if ($compileResult.compiler_out) { Write-Host $compileResult.compiler_out }
    if ($compileResult.compiler_err) { Write-Host $compileResult.compiler_err }
    throw "$testId`: diagnostic compile failed"
  }
  $binary = Join-Path $buildPath 'vc_lora_ground_diag_xiao_esp32s3.ino.bin'
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "$testId`: compile produced no application binary"
  }
  $flash = @($compileResult.builder_result.executable_sections_size |
    Where-Object name -eq 'text')[0]
  $ram = @($compileResult.builder_result.executable_sections_size |
    Where-Object name -eq 'data')[0]
  Write-Output "$testId COMPILE PASS cli=1.3.1 core=3.3.6 flash=$($flash.size) ram=$($ram.size)"
}

Require-ProductionTreesUnchanged
Write-Output "$testId PASS"
