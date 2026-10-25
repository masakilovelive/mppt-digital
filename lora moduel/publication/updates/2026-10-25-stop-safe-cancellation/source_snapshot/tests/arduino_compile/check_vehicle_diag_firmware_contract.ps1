param(
  [string]$ArduinoCli = 'C:\resources\app\lib\backend\resources\arduino-cli.exe',
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$IdeConfig = (Join-Path $env:USERPROFILE '.arduinoIDE\arduino-cli.yaml'),
  [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-VEHICLE-DIAG-001'

# These are the immutable production source-package baselines captured before
# the diagnostic sketch was introduced. The diagnostic build must be additive.
# Disposable Arduino IDE build/ artifacts are deliberately outside the hash.
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
  # Hash only the explicit Arduino source package: root entry sources, copied
  # core translation units, and copied core headers. IDE build/, exported
  # binaries, documentation, and editor metadata are intentionally out of scope.
  $packageFiles = @(
    Get-ChildItem -LiteralPath $root -File |
      Where-Object { $_.Extension -in @('.ino', '.h', '.hpp', '.cpp') }
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Filter '*.cpp'
    Get-ChildItem -LiteralPath (Join-Path $root 'vc_lora') -File -Filter '*.hpp'
  )
  $manifestLines = @($packageFiles |
    ForEach-Object {
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
  $vehicleTree = Join-Path $RepoRoot 'vc_lora_vehicle_xiao_esp32s3'
  $groundTree = Join-Path $RepoRoot 'vc_lora_ground_xiao_esp32s3'
  $vehicleHash = Get-TreeSha256 $vehicleTree
  $groundHash = Get-TreeSha256 $groundTree
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
        '^\s*#\s*if\s+defined\s*\(\s*VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS\s*\)') {
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

$diagRoot = Join-Path $RepoRoot 'vc_lora_vehicle_diag_xiao_esp32s3'
$diagSketch = Join-Path $diagRoot 'vc_lora_vehicle_diag_xiao_esp32s3.ino'
$diagHeader = Join-Path $diagRoot 'vc_lora_vehicle_diag.hpp'
$diagObserver = Join-Path $diagRoot 'vc_lora_vehicle_diag_observer.hpp'
$diagAdapter = Join-Path $diagRoot 'vc_lora_phase6_bridge.hpp'
$canonicalAdapter = Join-Path $RepoRoot 'firmware\phase6\vc_lora_phase6_bridge.hpp'
$canonicalUmbrella = Join-Path $RepoRoot `
  'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h'
$diagUmbrella = Join-Path $diagRoot 'VC_LoRa_Core.h'

Require-Text $diagSketch '#\s*define\s+VC_LORA_PHASE6_VEHICLE\s+1(?:\s|$)' `
  'Vehicle role macro'
Require-Text $diagSketch `
  '#\s*define\s+VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS\s+1(?:\s|$)' `
  'Vehicle-only diagnostics macro'
Require-Text $diagSketch `
  '#\s*define\s+VC_LORA_PHASE6_VEHICLE_HEARTBEAT_AB\s+1(?:\s|$)' `
  'Vehicle diagnostic heartbeat A/B macro'
Reject-Text $diagSketch 'VC_LORA_PHASE6_VEHICLE_PIXHAWK_UART_BPS' `
  'Vehicle diagnostic Pixhawk UART baud override'
Reject-Text $diagSketch '#\s*define\s+VC_LORA_PHASE6_GROUND\b' `
  'diagnostic sketch Ground role purity'
Require-Text $diagSketch '#\s*include\s*["<]VC_LoRa_Core\.h[">]' `
  'sketch-local core discovery'
Require-Text $diagSketch '#\s*include\s*["<]vc_lora_phase6_bridge\.hpp[">]' `
  'sketch-local Phase 6 adapter discovery'
Require-Text $diagSketch '#\s*include\s*["<]vc_lora_vehicle_diag\.hpp[">]' `
  'Vehicle diagnostic header discovery'
Require-Text $diagSketch `
  '#\s*include\s*["<]vc_lora_vehicle_diag_observer\.hpp[">]' `
  'Vehicle observer header discovery'

$productionVehicle = Join-Path $RepoRoot `
  'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino'
$productionGround = Join-Path $RepoRoot `
  'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'
foreach ($productionSketch in @($productionVehicle, $productionGround)) {
  Reject-Text $productionSketch 'VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS' `
    'production sketch diagnostics-macro purity'
  Reject-Text $productionSketch 'vc_lora_vehicle_diag\.hpp' `
    'production sketch diagnostic-header purity'
  Reject-Text $productionSketch 'VC_LORA_PHASE6_VEHICLE_PIXHAWK_UART_BPS' `
    'production sketch Pixhawk UART diagnostic override purity'
  Reject-Text $productionSketch 'VC_LORA_PHASE6_VEHICLE_HEARTBEAT_AB' `
    'production sketch heartbeat A/B purity'
}

Require-Text $diagSketch `
  'kHeartbeatIntervalMs\s*=\s*1000U' `
  'one-hertz diagnostic heartbeat interval'
Require-Text $diagSketch `
  'FD[^;]{0,220}09[^;]{0,220}FF[^;]{0,120}BE[^;]{0,300}3D[^;]{0,80}48' `
  'CRC-fixed MAVLink2 sys255/comp190 diagnostic heartbeat'
Require-Text $diagSketch `
  'pixhawk_serial\.availableForWrite\s*\(' `
  'non-blocking heartbeat UART capacity check'
Require-Text $diagSketch `
  'pixhawk_serial\.write\s*\(' `
  'diagnostic heartbeat UART write'
Require-Text $diagSketch `
  'observe_pixhawk_write\s*\(' `
  'diagnostic heartbeat observer accounting'

Require-Text $diagAdapter `
  'static_assert\s*\(\s*kTddProtocolVersion\s*==\s*3U\s*&&\s*kTddControlFrameSize\s*==\s*32U' `
  'diagnostic protocol v3 exact-32 compile contract'

# Diagnostics are observational and USB-CDC-only.  Binary production traffic
# may still use E220/Pixhawk UART write(), but diagnostic text must never do so.
Require-Text $diagHeader 'VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS' `
  'diagnostic compile guard'
Require-Text $diagHeader 'VC_LORA_PHASE6_VEHICLE' `
  'Vehicle-only compile guard'
Require-Text $diagHeader 'Serial\s*\.\s*begin\s*\(' `
  'USB CDC diagnostic output initialization'
Require-Text $diagHeader 'Serial\s*\.\s*(?:print|println|printf)\s*\(' `
  'USB CDC diagnostic text output'
Require-Text $diagHeader `
  'kQuery\s*\[\s*\]\s*=\s*"VCSTAT\?\\n"' `
  'exact command-driven VCSTAT query'
foreach ($tag in @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')) {
  Require-Text $diagHeader ([regex]::Escape($tag)) `
    "$tag machine-readable response"
}
Require-Text $diagHeader `
  'query_offset\s*==\s*kQuerySize[\s\S]{0,350}pending_snapshot\s*=\s*capture_snapshot\s*\(\s*\)[\s\S]{0,180}(?:report|snapshot)_pending\s*=\s*true' `
  'complete query captures one pending POD snapshot'
Require-Text $diagHeader `
  'VehicleTddState::DownlinkSend[\s\S]{0,500}!\s*radio_busy[\s\S]{0,250}!\s*pending_radio_action\.active[\s\S]{0,500}format_report\s*\(\s*pending_snapshot\s*\)' `
  'report formatting deferred to a radio-idle DownlinkSend safe point'
Reject-Text $diagHeader 'format_report\s*\(\s*capture_snapshot\s*\(' `
  'inline query-path report formatting'
Require-Text $diagHeader 'Serial\s*\.\s*availableForWrite\s*\(' `
  'non-blocking USB report backpressure'
Require-Text $diagHeader `
  'radio_bytes_ingested[\s\S]*radio_frames_validated[\s\S]*pixhawk_bytes_accepted[\s\S]*pixhawk_frames_ingested' `
  'uplink and Pixhawk stage counters'
Reject-Text $diagHeader `
  '(?:e220_serial|pixhawk_serial|Serial1|Serial2)\s*\.\s*(?:print|println|printf)\s*\(' `
  'non-USB diagnostic text output'
Reject-Text $diagHeader `
  '(?:e220_serial|pixhawk_serial)\s*\.\s*write\s*\(' `
  'diagnostic injection into E220 or Pixhawk UART'
Reject-Text $diagHeader 'VC_LORA_PHASE6_GROUND|GroundTddController|GroundMavlinkIngressAdapter' `
  'diagnostic header Ground-role purity'
Reject-Text $diagHeader '\b(?:delay|delayMicroseconds)\s*\(|\bString\b|\bmalloc\s*\(|\bnew\s+' `
  'blocking or dynamic-allocation diagnostic path'

Require-Text $diagObserver 'VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS' `
  'observer diagnostics-only compile guard'
Require-Text $diagObserver `
  '#\s*include\s*<vc_lora/mavlink_frame\.hpp>' `
  'observer canonical MAVLink include spelling'
Reject-Text $diagObserver `
  '#\s*include\s*"vc_lora/mavlink_frame\.hpp"' `
  'observer duplicate-path MAVLink include spelling'
Reject-Text $diagObserver `
  '(?:e220_serial|pixhawk_serial|Serial|Serial1|Serial2)\s*\.\s*(?:write|print|println|printf)\s*\(' `
  'observer transport-output purity'
Reject-Text $diagObserver `
  '\b(?:String|malloc|calloc|realloc|free)\b|\bnew\s+' `
  'observer dynamic-allocation purity'
foreach ($hook in @('observe_e220_raw', 'observe_radio_application',
    'observe_radio_control', 'observe_vehicle_state',
    'observe_pixhawk_write', 'observe_pixhawk_read',
    'observe_uplink_quarantine_begin', 'observe_uplink_ingest',
    'observe_uplink_terminal', 'observe_uplink_commit',
    'observe_uplink_abort', 'observe_uplink_controller')) {
  Require-Text $diagObserver ("\b{0}\s*\(" -f [regex]::Escape($hook)) `
    "$hook observer implementation"
}
Require-Text $diagObserver `
  'std::array\s*<\s*std::uint64_t\s*,\s*kVehicleTddStateCount\s*>\s+bytes' `
  'fixed-size outside-window byte histogram'
Require-Text $diagObserver `
  'std::array\s*<\s*std::uint64_t\s*,\s*kVehicleTddStateCount\s*>\s+frames' `
  'fixed-size outside-window frame histogram'
foreach ($state in @('DownlinkSend', 'DownlinkDrain', 'SendUlGrant',
    'GrantDrain', 'UplinkGuard', 'UplinkReceive', 'ReturnGuard')) {
  Require-Text $diagObserver `
    ("VehicleTddState::{0}" -f [regex]::Escape($state)) `
    "outside-window VehicleTddState histogram bucket $state"
}
foreach ($field in @('last_state', 'last_cycle', 'last_ms')) {
  Require-Text $diagObserver ("\b{0}\b" -f $field) `
    "outside-window last-arrival $field"
}
Require-Text $diagAdapter `
  'observe_radio_application\s*\([\s\S]{0,220}tdd_controller\.state\s*\(\s*\)[\s\S]{0,120}tdd_controller\.cycle_id\s*\(\s*\)[\s\S]{0,120}now_ms\s*\)' `
  'radio observer state/cycle/time correlation at byte arrival'
Require-Text $diagObserver `
  'std::array\s*<\s*std::uint64_t\s*,\s*kVehicleTddStateCount\s*>\s+done' `
  'fixed-size decoded UL_DONE state histogram'
Require-Text $diagObserver `
  'std::array\s*<\s*std::uint64_t\s*,\s*kVehicleTddStateCount\s*>\s+idle' `
  'fixed-size decoded UL_IDLE state histogram'
Require-Text $diagObserver `
  'struct\s+TargetEvent[\s\S]*struct\s+TargetUplinkSnapshot' `
  'v5 target msg20 POD snapshot and event record'
Require-Text $diagObserver `
  'std::array\s*<\s*TargetEvent\s*,\s*kTargetEventCapacity\s*>\s+events' `
  'fixed-capacity target event ring'
Require-Text $diagObserver `
  'static_assert\s*\(\s*std::is_trivially_copyable[^;]+TargetUplinkSnapshot' `
  'target snapshot POD compile contract'
Require-Text $diagAdapter `
  'observe_radio_control\s*\([\s\S]{0,180}event\.control\.message[\s\S]{0,180}tdd_controller\.state\s*\(\s*\)[\s\S]{0,120}tdd_controller\.cycle_id\s*\(\s*\)[\s\S]{0,120}now_ms\s*\)[\s\S]{0,450}vehicle_uplink_recovery\.on_terminal' `
  'decoded control observation before recovery/controller mutation'
Require-Text $diagAdapter `
  'observe_vehicle_state\s*\(\s*tdd_controller\.state\s*\(\s*\)\s*,\s*tdd_controller\.cycle_id\s*\(\s*\)\s*,\s*now_ms\s*\)' `
  'Vehicle state-entry timing observation'

$diagAdapterText = Get-Content -Raw -LiteralPath $diagAdapter
$canonicalAdapterText = Get-Content -Raw -LiteralPath $canonicalAdapter
$diagnosticBlockMatches = [regex]::Matches(
  $diagAdapterText,
  '(?ms)^\s*#\s*if\s+defined\s*\(\s*VC_LORA_PHASE6_VEHICLE_DIAGNOSTICS\s*\)\s*$' +
  '(?<body>.*?)^\s*#\s*endif\b[^\r\n]*$')
if ($diagnosticBlockMatches.Count -eq 0) {
  throw "$testId`: diagnostic adapter has no guarded observer-hook blocks"
}
$diagnosticBlocks = ($diagnosticBlockMatches | ForEach-Object {
    $_.Groups['body'].Value
  }) -join "`n"
$expectedObserverHooks = @(
  'observe_e220_raw',
  'observe_radio_application',
  'observe_radio_control',
  'observe_vehicle_state',
  'observe_pixhawk_write',
  'observe_pixhawk_read',
  'observe_uplink_quarantine_begin',
  'observe_uplink_ingest',
  'observe_uplink_terminal',
  'observe_uplink_commit',
  'observe_uplink_abort',
  'observe_uplink_controller'
)
foreach ($hook in $expectedObserverHooks) {
  if ($diagnosticBlocks -notmatch ("\b{0}\s*\(" -f [regex]::Escape($hook))) {
    throw "$testId`: diagnostics-only adapter lacks $hook observer hook"
  }
}
$actualObserverHooks = @([regex]::Matches(
    $diagnosticBlocks, '\bobserve_[a-z0-9_]+\s*\(') |
  ForEach-Object { $_.Value -replace '\s*\($', '' } | Sort-Object -Unique)
Require-SameNameSet $expectedObserverHooks $actualObserverHooks `
  'diagnostics-only observer-hook name set'
if ($diagnosticBlocks -match
    '(?:e220_serial|pixhawk_serial|Serial|Serial1|Serial2)\s*\.\s*(?:write|print|println|printf)\s*\(') {
  throw "$testId`: diagnostics-only adapter block writes to a transport"
}
$strippedDiagAdapter = Get-AdapterWithoutDiagnosticBlocks $diagAdapterText
$strippedCanonicalAdapter =
  Get-AdapterWithoutDiagnosticBlocks $canonicalAdapterText
if ($strippedDiagAdapter -cne $strippedCanonicalAdapter) {
  throw "$testId`: diagnostic adapter has changes outside guarded observer-hook blocks"
}

$diagHeaderText = Get-Content -Raw -LiteralPath $diagHeader
$statusFormatMatches = @([regex]::Matches(
    $diagHeaderText, 'VCSTAT(?<tag>[123])[^"\r\n]*q=%[^"\r\n]*ms=%[^"\r\n]*'))
if ($statusFormatMatches.Count -ne 3 -or
    @($statusFormatMatches | ForEach-Object {
        $_.Groups['tag'].Value
      } | Sort-Object -Unique).Count -ne 3) {
  throw "$testId`: VCSTAT1/2/3 must each carry q and ms from one snapshot"
}
$queryArgumentCount = [regex]::Matches(
  $diagHeaderText,
  'static_cast<unsigned long>\s*\(\s*s\.query_id\s*\)').Count
$timeArgumentCount = [regex]::Matches(
  $diagHeaderText,
  'static_cast<unsigned long long>\s*\(\s*s\.now_ms\s*\)').Count
if ($queryArgumentCount -ne 3 -or $timeArgumentCount -ne 3) {
  throw "$testId`: VCSTAT1/2/3 do not format the same snapshot q/ms fields"
}
Require-Text $diagHeader `
  '(?:query|snapshot)_(?:sequence|id)[\s\S]{0,300}(?:\+\+|\+=\s*1)' `
  'monotonically increasing query snapshot sequence'
foreach ($key in @('owbds', 'owbdd', 'owbsg', 'owbgd', 'owbug', 'owbur',
    'owbrg', 'owfds', 'owfdd', 'owfsg', 'owfgd', 'owfug', 'owfur',
    'owfrg', 'owls', 'owlcy', 'owlms',
    'udds', 'uddd', 'udsg', 'udgd', 'udug', 'udur', 'udrg',
    'uids', 'uidd', 'uisg', 'uigd', 'uiug', 'uiur', 'uirg',
    'uclt', 'ucls', 'uclcy', 'uclms', 'rgseen', 'rgems',
    'owftv', 'owfel', 'owfrem')) {
  Require-Text $diagHeader ("\b{0}=%" -f $key) `
    "VCSTAT outside-window state field $key"
}
foreach ($key in @('tl', 'tcy', 'tbms', 'tfms', 'tlms', 'tfs', 'tls',
    'trb', 'tbb', 'tfc', 'tis', 'tdms', 'tdst', 'tdcy', 'tdsid',
    'tdac', 'tdmx', 'tdgp', 'tts', 'tpf', 'ttk', 'tei', 'tcb', 'tcf',
    'td620', 'td722', 'tto', 'tca', 'tar', 'evn', 'evo', 'ev')) {
  Require-Text $diagHeader ("\b{0}=%" -f $key) `
    "VCSTAT v5 target-uplink field $key"
}
Require-Text $diagHeader 'v=5' 'Vehicle diagnostics schema v5'
Require-Text $diagHeader `
  'kReportCapacity\s*=\s*6144U' `
  'bounded report buffer sized for worst-case state diagnostics'

$queryTool = Join-Path $RepoRoot 'tools\vehicle_diag_query.ps1'
Require-Text $queryTool '\[string\]\s*\$Port\s*=\s*''COM3''' `
  'Vehicle USB diagnostic COM default'
Require-Text $queryTool '\[int\]\s*\$Baud\s*=\s*115200' `
  'Vehicle USB diagnostic baud default'
Require-Text $queryTool 'GetBytes\s*\(\s*"VCSTAT\?`n"\s*\)' `
  'query tool exact VCSTAT request'
foreach ($tag in @('VCSTAT1', 'VCSTAT2', 'VCSTAT3')) {
  Require-Text $queryTool ([regex]::Escape($tag)) `
    "query tool $tag response contract"
}
Require-Text $queryTool 'DtrEnable\s*=\s*\$false' `
  'query tool DTR disabled'
Require-Text $queryTool 'RtsEnable\s*=\s*\$false' `
  'query tool RTS disabled'
& $queryTool -SelfTest
if (-not $?) {
  throw "$testId`: offline query-tool self-test failed"
}

# The dedicated sketch must keep the exact canonical core. Its adapter may
# differ only inside the guarded observer-hook blocks validated above.
Require-SameFile $canonicalUmbrella $diagUmbrella `
  'diagnostic sketch-local core umbrella'

$coreSources = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'core\src') `
  -File -Filter '*.cpp')
$coreHeaders = @(Get-ChildItem -LiteralPath `
  (Join-Path $RepoRoot 'core\include\vc_lora') -File -Filter '*.hpp')
foreach ($source in $coreSources) {
  Require-SameFile $source.FullName `
    (Join-Path $diagRoot "src\$($source.Name)") `
    "diagnostic sketch-local source $($source.Name)"
}
foreach ($header in $coreHeaders) {
  Require-SameFile $header.FullName `
    (Join-Path $diagRoot "vc_lora\$($header.Name)") `
    "diagnostic sketch-local header $($header.Name)"
}
Require-SameNameSet @($coreSources | ForEach-Object { $_.Name }) `
  @(Get-ChildItem -LiteralPath (Join-Path $diagRoot 'src') -File `
      -Filter '*.cpp' | ForEach-Object { $_.Name }) `
  'diagnostic sketch-local source basename set'
Require-SameNameSet @($coreHeaders | ForEach-Object { $_.Name }) `
  @(Get-ChildItem -LiteralPath (Join-Path $diagRoot 'vc_lora') -File `
      -Filter '*.hpp' | ForEach-Object { $_.Name }) `
  'diagnostic sketch-local header basename set'

$packagedFiles = @($diagSketch, $diagHeader, $diagObserver, $diagAdapter,
    $diagUmbrella) +
  @($coreSources | ForEach-Object { Join-Path $diagRoot "src\$($_.Name)" }) +
  @($coreHeaders | ForEach-Object { Join-Path $diagRoot "vc_lora\$($_.Name)" })
foreach ($packagedFile in $packagedFiles) {
  Reject-Text $packagedFile '#\s*include\s*["<]\s*\.\.' `
    'self-contained diagnostic source'
}

# Pin direction is expressed as MCU TX/RX in HardwareSerial.begin(rx, tx).
Require-Text $diagAdapter `
  'static_assert\s*\(kE220M0Pin\s*==\s*D0\s*&&\s*kE220M1Pin\s*==\s*D1' `
  'E220 M0/M1 fixed wiring'
Require-Text $diagAdapter `
  'static_assert\s*\(kE220TxPin\s*==\s*D2\s*&&\s*kE220RxPin\s*==\s*D3' `
  'E220 UART fixed wiring'
Require-Text $diagAdapter 'static_assert\s*\(kE220AuxPin\s*==\s*D8' `
  'E220 AUX fixed wiring'
Require-Text $diagAdapter `
  'static_assert\s*\(kPixhawkTxPin\s*==\s*D6\s*&&\s*kPixhawkRxPin\s*==\s*D7' `
  'Pixhawk UART fixed wiring'
Require-Text $diagAdapter `
  'pixhawk_uart_bps\s*==\s*57600U[\s\S]{0,120}e220_uart_bps\s*==\s*115200U' `
  'fixed UART baud rates'
Require-Text $diagAdapter `
  'e220_serial\.begin\s*\(FixedFirmwareContract::e220_uart_bps\s*,\s*SERIAL_8N1\s*,\s*kE220RxPin\s*,\s*kE220TxPin\s*\)' `
  'E220 HardwareSerial RX/TX binding'
Require-Text $diagAdapter `
  'pixhawk_serial\.begin\s*\(FixedFirmwareContract::pixhawk_uart_bps\s*,\s*SERIAL_8N1\s*,\s*kPixhawkRxPin\s*,\s*kPixhawkTxPin\s*\)' `
  'Pixhawk HardwareSerial RX/TX binding'
Reject-Text $diagAdapter `
  'VC_LORA_PHASE6_VEHICLE_PIXHAWK_UART_BPS|pixhawk_serial\.updateBaudRate' `
  'Vehicle diagnostic Pixhawk UART baud override'

if (-not $SkipCompile) {
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    throw "$testId`: Arduino IDE bundled CLI not found at $ArduinoCli"
  }
  $cliVersion = (& $ArduinoCli version --format json | ConvertFrom-Json)
  if ($cliVersion.VersionString -ne '1.3.1') {
    throw "$testId`: expected Arduino IDE bundled CLI 1.3.1, got $($cliVersion.VersionString)"
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
  $buildPath = Join-Path $env:TEMP "vc_lora_vehicle_diag_$PID"
  $compileOutput = @(& $ArduinoCli @globalArgs compile --fqbn $Fqbn `
    --warnings all --clean --build-path $buildPath --json $diagRoot 2>&1)
  $compileExit = $LASTEXITCODE
  $compileText = $compileOutput -join "`n"
  try {
    $compileResult = $compileText | ConvertFrom-Json
  } catch {
    Write-Host $compileText
    throw "$testId`: Arduino IDE bundled CLI returned invalid JSON"
  }
  if ($compileExit -ne 0 -or -not $compileResult.success) {
    if ($compileResult.compiler_out) {
      Write-Host $compileResult.compiler_out.TrimEnd()
    }
    if ($compileResult.compiler_err) {
      Write-Host $compileResult.compiler_err.TrimEnd()
    }
    throw "$testId`: plain direct-open diagnostic compile failed"
  }
  $binary = Join-Path $buildPath `
    'vc_lora_vehicle_diag_xiao_esp32s3.ino.bin'
  if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "$testId`: compile produced no application binary"
  }
  $flash = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'text' })[0]
  $ram = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'data' })[0]
  if (-not $flash -or -not $ram) {
    throw "$testId`: compile returned no flash/RAM sizes"
  }
  Write-Output "$testId COMPILE PASS cli=1.3.1 core=3.3.6 flash=$($flash.size) ram=$($ram.size)"
}

Require-ProductionTreesUnchanged
Write-Output "$testId PASS"
