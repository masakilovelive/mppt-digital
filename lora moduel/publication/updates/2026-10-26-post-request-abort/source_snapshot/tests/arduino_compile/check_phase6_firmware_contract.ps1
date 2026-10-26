param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'

function Require-Text {
  param(
    [string]$Path,
    [string]$Pattern,
    [string]$Description
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "FW-ARDUINO-CONTRACT-001: missing $Description at $Path"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text -notmatch $Pattern) {
    throw "FW-ARDUINO-CONTRACT-001: $Description does not satisfy /$Pattern/"
  }
}

function Reject-Text {
  param(
    [string]$Path,
    [string]$Pattern,
    [string]$Description
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "FW-ARDUINO-CONTRACT-001: missing $Description at $Path"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text -match $Pattern) {
    throw "FW-ARDUINO-CONTRACT-001: $Description unexpectedly matches /$Pattern/"
  }
}

function Require-SameFile {
  param(
    [string]$Expected,
    [string]$Actual,
    [string]$Description
  )
  if (-not (Test-Path -LiteralPath $Expected) -or
      -not (Test-Path -LiteralPath $Actual)) {
    throw "FW-ARDUINO-CONTRACT-001: missing $Description"
  }
  $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Expected).Hash
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Actual).Hash
  if ($expectedHash -ne $actualHash) {
    throw "FW-ARDUINO-CONTRACT-001: $Description differs from host core"
  }
}

function Require-SameNameSet {
  param(
    [string[]]$Expected,
    [string[]]$Actual,
    [string]$Description
  )
  $difference = @(Compare-Object `
    -ReferenceObject @($Expected | Sort-Object) `
    -DifferenceObject @($Actual | Sort-Object))
  if ($difference.Count -ne 0) {
    $details = ($difference | ForEach-Object {
        "$($_.SideIndicator)$($_.InputObject)"
      }) -join ', '
    throw "FW-ARDUINO-CONTRACT-001: $Description differs: $details"
  }
}

$vehicle = Join-Path $RepoRoot 'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino'
$ground = Join-Path $RepoRoot 'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'
$adapter = Join-Path $RepoRoot 'firmware\phase6\vc_lora_phase6_bridge.hpp'
$syncScript = Join-Path $RepoRoot 'tools\sync_arduino_sketch_core.ps1'
$candidatePackagingContract = Join-Path $RepoRoot `
  'tests\arduino_compile\check_high_speed_candidate_packaging_contract.ps1'
$canonicalCandidateRoot = Join-Path $RepoRoot 'firmware\high_speed'
$candidateHeaderNames = @(
  'e220_high_speed_transport_model.hpp',
  'high_speed_phase6_adapter.hpp',
  'phase6_bulk_rx_tail_ledger.hpp',
  'phase6_high_speed_radio_session.hpp',
  'phase6_high_speed_role_config.hpp',
  'phase6_radio_writer_arbiter.hpp',
  'peer_completion_receipt.hpp',
  'r19_runtime_fail_diagnostic.hpp',
  'r19_runtime_stage_record.hpp',
  'terminal_ack_bridge.hpp',
  'terminal_ack_producer.hpp',
  'terminal_ack_wire.hpp',
  'vc_lora_high_speed_candidate.hpp'
)

Require-Text $vehicle 'VC_LORA_PHASE6_VEHICLE' 'Vehicle Phase 6 role selection'
Require-Text $ground 'VC_LORA_PHASE6_GROUND' 'Ground Phase 6 role selection'
Require-Text $vehicle '["<]vc_lora_phase6_bridge\.hpp[">]' `
  'Vehicle sketch-local adapter include'
Require-Text $ground '["<]vc_lora_phase6_bridge\.hpp[">]' `
  'Ground sketch-local adapter include'
Require-Text $vehicle '["<]VC_LoRa_Core\.h[">]' `
  'Vehicle sketch-local core discovery'
Require-Text $ground '["<]VC_LoRa_Core\.h[">]' `
  'Ground sketch-local core discovery'
Require-Text $syncScript `
  '\[switch\]\s*\$IncludeR19HighSpeedCandidate' `
  'explicit R19 candidate packaging opt-in'
Require-Text $syncScript `
  'candidate_packaging=\$candidateMode' `
  'auditable R19 candidate packaging mode output'

foreach ($sketch in @($vehicle, $ground)) {
  $text = Get-Content -Raw -LiteralPath $sketch
  if ($text -match 'vc_lora_bridge_xiao_esp32c3') {
    throw 'FW-ARDUINO-CONTRACT-001: Phase 6 S3 sketch still includes the legacy C3 bridge'
  }
  if ($text -match `
      'high_speed_phase6_adapter|(?:Ground|Vehicle)HighSpeedPhase6Adapter') {
    throw 'FW-ARDUINO-CONTRACT-001: production wrapper enables the unaccepted R19 candidate'
  }
}

foreach ($entry in @(
    @('FixedFirmwareContract', 'fixed product contract'),
    @('esp_timer_get_time', '64-bit monotonic ESP timer'),
    @('Preferences', 'persistent boot/session identity'),
    @('FirmwareStartupContract', 'startup fail-close gate'),
    @('E220WriteContract', 'post-write AUX contract'),
    @('GroundMavlinkIngressAdapter', 'frame-atomic Ground ingress'),
    @('LocalEgressAdapter', 'local UART backpressure'),
    @('MavlinkFrameScheduler', 'Vehicle MAVLink scheduler'),
    @('VehicleTddController', 'Vehicle TDD controller'),
    @('GroundTddController', 'Ground TDD controller')
  )) {
  Require-Text $adapter ([regex]::Escape($entry[0])) $entry[1]
}

$adapterText = Get-Content -Raw -LiteralPath $adapter
if ($adapterText -notmatch `
    '#ifndef\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE[\s\S]*?#define\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE\s+0' -or
    $adapterText -notmatch `
    '#if\s+VC_LORA_R19_HIGH_SPEED_CANDIDATE[\s\S]*?#include\s+"high_speed/high_speed_phase6_adapter\.hpp"') {
  throw 'FW-ARDUINO-CONTRACT-001: R19 candidate is not isolated by a default-off feature gate'
}
if ($adapterText -match 'Serial\s*\.\s*(print|println|printf)') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground-capable adapter contains USB debug text output'
}
if ($adapterText -notmatch
      'void\s+pump_ground_usb_egress\(std::uint64_t\s+now_ms\)[\s\S]{0,260}const\s+std::uint64_t\s+observed_ms\s*=\s*std::max\(now_ms,\s*monotonic_now_ms\(\)\)[\s\S]{0,260}update_ground_usb_connection\(observed_ms\)') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground USB pump uses a stale loop timestamp for host-presence decisions'
}
if ($adapterText -notmatch
      'void\s+update_ground_usb_connection\(std::uint64_t\s+now_ms\)[\s\S]{0,1500}had_irreversible_usb_bytes[\s\S]{0,500}ground_paced_heartbeat_commit_active[\s\S]{0,300}ground_parameter_publish_commit_active[\s\S]{0,300}egress\.write_pending\(\)[\s\S]{0,300}egress\.queued_bytes\(\)[\s\S]{0,500}if\s*\(had_irreversible_usb_bytes\)[\s\S]{0,180}latch_runtime_fail_closed\(\)') {
  throw 'FW-ARDUINO-CONTRACT-001: confirmed Ground USB disconnect can retain an irreversibly admitted frame suffix'
}
if ($adapterText -notmatch
    'radio_busy\s*=\s*true[\s\S]*finish_payload\(TxResult::Accepted,\s*accepted_at_ms\)') {
  throw 'FW-ARDUINO-CONTRACT-001: full UART acceptance is not committed at the TX start timestamp'
}
if ($adapterText -notmatch
    'take_write_completion\(\)[\s\S]*radio_busy\s*=\s*false') {
  throw 'FW-ARDUINO-CONTRACT-001: AUX completion does not release the independent radio-busy gate'
}
$groundParserPush = $adapterText.IndexOf(
  'ground_radio_application_parser.push')
$groundFrameReady = $adapterText.IndexOf(
  'if (parse_status == MavlinkParseStatus::FrameReady)',
  $groundParserPush + 1)
$groundValidatedHandlerCall = $adapterText.IndexOf(
  'handle_ground_validated_frame(frame, now_ms)',
  $groundFrameReady + 1)
$groundValidatedHandler = $adapterText.IndexOf(
  'void handle_ground_validated_frame')
$groundHandlerPreclassify = $adapterText.IndexOf(
  'preclassify_vehicle_frame', $groundValidatedHandler + 1)
$groundHandlerBacklogAdmission = $adapterText.IndexOf(
  'ground_usb_ordered_backlog.enqueue', $groundHandlerPreclassify + 1)
$groundHandlerDirectAdmission = $adapterText.IndexOf(
  'radio_application_endpoint.admit_validated_frame(frame)',
  $groundHandlerPreclassify + 1)
$groundHandlerPostAdmission = $adapterText.IndexOf(
  'note_ground_usb_admission(frame, status, now_ms)',
  $groundHandlerDirectAdmission + 1)
if ($adapterText -notmatch 'MavlinkValidatedLocalEgressAdapter' -or
    $groundParserPush -lt 0 -or $groundFrameReady -le $groundParserPush -or
    $groundValidatedHandlerCall -le $groundFrameReady -or
    $groundValidatedHandler -lt 0 -or
    $groundHandlerPreclassify -le $groundValidatedHandler -or
    $groundHandlerBacklogAdmission -le $groundHandlerPreclassify -or
    $groundHandlerDirectAdmission -le $groundHandlerPreclassify) {
  throw 'FW-ARDUINO-CONTRACT-001: radio bytes can reach a local UART before complete MAVLink validation'
}
if ($adapterText -notmatch
      'VC_LORA_PHASE6_GROUND[\s\S]{0,900}LocalEgressOverflowPolicy::DropNewestFrame') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground USB endpoint lacks recoverable complete-frame overflow policy'
}
if ($groundHandlerPostAdmission -le $groundHandlerDirectAdmission -or
    $adapterText -notmatch
      'void\s+note_ground_usb_admission[\s\S]{0,700}ground_parameter_proxy\.on_vehicle_frame\(frame,\s*usb_queued,\s*now_ms\)') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground must quarantine proxy frames before USB admission and commit only afterward'
}
if ($adapterText -notmatch
      'Classify a newly arrived GCS PARAM_SET[\s\S]{0,500}collect_local_ingress\(now_ms\);[\s\S]{0,300}deliver_radio_bytes\(now_ms\);') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground must classify GCS writes before same-loop RF delivery'
}
if ($adapterText -notmatch
      'std::uint64_t\s+ground_usb_transport_published_bytes' -or
    $adapterText -notmatch
      'ground_usb_transport_epoch_healthy[\s\S]{0,2600}GroundUsbTransportEpochSnapshot[\s\S]{0,500}assess_ground_usb_transport_epoch[\s\S]{0,700}RecoverableBoundary[\s\S]{0,700}discard_ground_usb_rx_bytes[\s\S]{0,400}discard_ground_ordered_backlog[\s\S]{0,300}discard_ground_held_heartbeats[\s\S]{0,300}ground_usb_parser\s*=\s*\{\}[\s\S]{0,300}ground_usb_observed_loss_epoch\s*=\s*observed' -or
    $adapterText -notmatch
      'ground_usb_transport_epoch_healthy[\s\S]{0,2600}UnsafeLoss|ground_usb_transport_epoch_healthy[\s\S]{0,2600}disposition\s*!=[\s\S]{0,200}RecoverableBoundary[\s\S]{0,500}latch_runtime_fail_closed') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground clean loss-epoch recovery is not isolated from unsafe fail-close'
}
$publishedWatermarkAssignments = [regex]::Matches(
  $adapterText,
  'ground_usb_transport_published_bytes\s*=\s*[\r\n\s]*radio_application_endpoint\.egress\(\)\.stats\(\)\.bytes_committed').Count
if ($publishedWatermarkAssignments -lt 3 -or
    $adapterText -notmatch
      'had_irreversible_usb_bytes[\s\S]{0,500}bytes_committed\s*!=[\s\S]{0,120}ground_usb_transport_published_bytes[\s\S]{0,900}discard_ground_usb_rx_bytes[\s\S]{0,200}ground_usb_parser\s*=\s*\{\}') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground USB publication watermark does not cover both fences, setup, and disconnect'
}
if ($adapterText -notmatch
      'Classify a newly arrived GCS PARAM_SET[\s\S]{0,500}update_ground_usb_connection\(now_ms\);[\s\S]{0,250}ground_usb_runtime_healthy_or_retire\(now_ms\)[\s\S]{0,250}collect_local_ingress\(now_ms\);') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground can consume pre-reset GCS bytes before loss-epoch isolation'
}
if ($adapterText -notmatch
      'ground_ingress\.admit_validated_frame\(request\)[\s\S]{0,300}mark_request_admitted\(token,\s*now_ms\)[\s\S]{0,300}ground_proxy_request_admitted\s*=\s*true') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground must mark an admitted proxy request before stale-frame tracking'
}
if ($adapterText -notmatch
      'mark_request_dequeued[\s\S]{0,500}ground_proxy_request_done_goal\s*=\s*link_diagnostics\.done_tx\s*\+\s*1U[\s\S]{0,1400}link_diagnostics\.done_tx\s*>=\s*ground_proxy_request_done_goal[\s\S]{0,900}complete_request_tx[\s\S]{0,900}ground_parameter_proxy\.tick\(now_ms\)') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground proxy must complete explicit v2 UL_DONE before the inclusive watchdog tick'
}
if ($adapterText -notmatch
      'request_admission_abandoned[\s\S]{0,700}latch_runtime_fail_closed') {
  throw 'FW-ARDUINO-CONTRACT-001: stalled admitted proxy request does not fail closed'
}
$frontFrameBinding = $adapterText.IndexOf(
  'input.front_frame_bytes = ground_ingress.front_frame_remaining()')
$transactionTargetBinding = $adapterText.IndexOf(
  'transaction_target_bytes()', $frontFrameBinding + 1)
$wholeFrameWirePreview = $adapterText.IndexOf(
  'ground_ingress.front_frame_wire_bytes()', $transactionTargetBinding + 1)
if ($frontFrameBinding -lt 0 -or
    $transactionTargetBinding -le $frontFrameBinding -or
    $wholeFrameWirePreview -le $transactionTargetBinding) {
  throw 'FW-ARDUINO-CONTRACT-001: Ground does not bind one complete front frame to the v2 transaction target'
}
if ($adapterText -match
      'complete_uplink_frame|complete_frame\(\)') {
  throw 'FW-ARDUINO-CONTRACT-001: implicit-frame-terminal v3 path remains in Phase 6 adapter'
}
if ($adapterText -notmatch
      'DroppedOverflow[\s\S]{0,300}radio_application_endpoint\.fail_closed\(\)[\s\S]{0,200}latch_runtime_fail_closed') {
  throw 'FW-ARDUINO-CONTRACT-001: Ground USB capacity drop is not separated from fatal endpoint failure'
}
if ($adapterText -notmatch
      'radio_receive_window\(\)[\s\S]*uplink_data_outside_receive_window' -or
    $adapterText -notmatch
      'GroundTddState::WaitGrant[\s\S]*half_duplex_drop_count') {
  throw 'FW-ARDUINO-CONTRACT-001: RF application bytes are not gated to the role receive window'
}
if ($adapterText -notmatch
      'void\s+reset_closed_radio_ingress\(\)[\s\S]{0,700}radio_demux\.reset\(\)[\s\S]{0,300}radio_application_endpoint\.reset_parser\(\)') {
  throw 'FW-ARDUINO-CONTRACT-001: closed receive windows do not clear transient RF/MAVLink parser residue'
}
if (([regex]::Matches($adapterText,
      'reset_closed_radio_ingress\(')).Count -lt 4) {
  throw 'FW-ARDUINO-CONTRACT-001: receive-window residue is not cleared before/after RF drain and after TDD tick'
}
if ($adapterText -match 'radio_application_endpoint\.reset\(\)') {
  throw 'FW-ARDUINO-CONTRACT-001: receive-window reset must preserve completed local egress frames'
}
if ($adapterText -notmatch
      'kPixhawkLinkHeartbeatIntervalMs\s*=\s*1000U' -or
    $adapterText -notmatch
      'void\s+service_pixhawk_link_heartbeat\(std::uint64_t\s+now_ms\)[\s\S]{0,2600}encode_mavlink_v2\([\s\S]{0,500}255U,\s*190U,\s*0U' -or
    $adapterText -notmatch
      'service_pixhawk_link_heartbeat[\s\S]{0,2600}radio_application_endpoint\.egress\(\)[\s\S]{0,500}egress\.free_bytes\(\)[\s\S]{0,900}egress\.ingest\(') {
  throw 'FW-ARDUINO-CONTRACT-001: Vehicle lacks the fixed 1-Hz frame-atomic Pixhawk link heartbeat'
}
if ($adapterText -match
      'service_pixhawk_link_heartbeat[\s\S]{0,2600}pixhawk_serial\.write\(') {
  throw 'FW-ARDUINO-CONTRACT-001: Pixhawk link heartbeat bypasses the ordered local egress FIFO'
}
if ($adapterText -notmatch
      'service_pixhawk_link_heartbeat\(now_ms\);[\s\S]{0,400}deliver_radio_bytes\(now_ms\);') {
  throw 'FW-ARDUINO-CONTRACT-001: Pixhawk link heartbeat is not queued before same-loop RF uplink data'
}

$coreSources = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'core\src') `
  -Filter '*.cpp'
$coreHeaders = Get-ChildItem -LiteralPath `
  (Join-Path $RepoRoot 'core\include\vc_lora') -Filter '*.hpp'
$canonicalUmbrella = Join-Path $RepoRoot `
  'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h'
foreach ($sketch in @($vehicle, $ground)) {
  $sketchRoot = Split-Path -Parent $sketch
  $sketchRole = if ($sketch -eq $vehicle) { 'Vehicle' } else { 'Ground' }
  Require-SameFile $adapter `
    (Join-Path $sketchRoot 'vc_lora_phase6_bridge.hpp') `
    "$sketchRole sketch-local adapter copy"
  Require-SameFile $canonicalUmbrella `
    (Join-Path $sketchRoot 'VC_LoRa_Core.h') `
    "$sketchRole sketch-local core umbrella"
  foreach ($source in $coreSources) {
    $localSource = Join-Path $sketchRoot ("src\$($source.Name)")
    Require-SameFile $source.FullName $localSource `
      "$sketchRole sketch-local source copy $($source.Name)"
  }
  foreach ($header in $coreHeaders) {
    $localHeader = Join-Path $sketchRoot ("vc_lora\$($header.Name)")
    Require-SameFile $header.FullName $localHeader `
      "$sketchRole sketch-local header copy $($header.Name)"
  }
  $actualSourceNames = @(Get-ChildItem -LiteralPath `
      (Join-Path $sketchRoot 'src') -File -Filter '*.cpp' |
      ForEach-Object { $_.Name })
  $actualHeaderNames = @(Get-ChildItem -LiteralPath `
      (Join-Path $sketchRoot 'vc_lora') -File -Filter '*.hpp' |
      ForEach-Object { $_.Name })
  Require-SameNameSet @($coreSources | ForEach-Object { $_.Name }) `
    $actualSourceNames "$sketchRole sketch-local source basename set"
  Require-SameNameSet @($coreHeaders | ForEach-Object { $_.Name }) `
    $actualHeaderNames "$sketchRole sketch-local header basename set"
  $staleSourceProxies = @(Get-ChildItem -LiteralPath `
      (Join-Path $sketchRoot 'src') -Filter 'proxy_*.cpp' `
      -ErrorAction SilentlyContinue)
  $staleHeaderProxies = @(Get-ChildItem -LiteralPath `
      (Join-Path $sketchRoot 'src\vc_lora') -Filter '*.hpp' `
      -ErrorAction SilentlyContinue)
  if ($staleSourceProxies.Count -ne 0 -or $staleHeaderProxies.Count -ne 0) {
    throw "FW-ARDUINO-CONTRACT-001: $sketchRole contains stale temp-relative proxies"
  }
  $candidateTarget = Join-Path $sketchRoot 'high_speed'
  $presentCandidateNames = @($candidateHeaderNames | Where-Object {
      Test-Path -LiteralPath (Join-Path $candidateTarget $_) -PathType Leaf
    })
  if ($presentCandidateNames.Count -ne 0) {
    if ($presentCandidateNames.Count -ne $candidateHeaderNames.Count) {
      throw "FW-ARDUINO-CONTRACT-001: $sketchRole has a partial R19 candidate package"
    }
    $actualCandidateNames = @(Get-ChildItem -LiteralPath $candidateTarget `
        -File -Filter '*.hpp' | ForEach-Object { $_.Name })
    Require-SameNameSet $candidateHeaderNames $actualCandidateNames `
      "$sketchRole R19 candidate header basename set"
    foreach ($candidateName in $candidateHeaderNames) {
      $canonicalCandidate = Join-Path $canonicalCandidateRoot $candidateName
      $packagedCandidate = Join-Path $candidateTarget $candidateName
      Require-SameFile $canonicalCandidate $packagedCandidate `
        "$sketchRole R19 candidate copy $candidateName"
      Reject-Text $packagedCandidate '#\s*include\s*["<]\s*\.\.' `
        "$sketchRole R19 candidate must not escape the sketch"
    }
  }
  $packagedSources = @(
    (Join-Path $sketchRoot 'VC_LoRa_Core.h'),
    (Join-Path $sketchRoot 'vc_lora_phase6_bridge.hpp')
  ) + @($coreSources | ForEach-Object {
      Join-Path $sketchRoot ("src\$($_.Name)")
    }) + @($coreHeaders | ForEach-Object {
      Join-Path $sketchRoot ("vc_lora\$($_.Name)")
    })
  foreach ($packagedSource in $packagedSources) {
    Reject-Text $packagedSource '#\s*include\s*["<]\s*\.\.' `
      "$sketchRole packaged source must not escape the sketch"
  }
}

$compileScript = Join-Path $RepoRoot 'tools\compile_arduino.ps1'
Reject-Text $compileScript '--library(?:\s|$)' `
  'sequential compile must use normal sketch-local dependency discovery'

if (-not (Test-Path -LiteralPath $candidatePackagingContract -PathType Leaf)) {
  throw 'FW-ARDUINO-CONTRACT-001: missing focused R19 candidate packaging contract'
}
try {
  $candidatePackagingOutput = @(& $candidatePackagingContract `
      -RepoRoot $RepoRoot 2>&1)
} catch {
  throw "FW-ARDUINO-CONTRACT-001: R19 candidate packaging contract failed: $($_.Exception.Message)"
}
if (($candidatePackagingOutput -join "`n") -notmatch `
    'FW-HIGH-SPEED-CANDIDATE-PACKAGING-001 PASS') {
  throw 'FW-ARDUINO-CONTRACT-001: R19 candidate packaging contract did not report PASS'
}

Write-Output 'FW-ARDUINO-CONTRACT-001 PASS'
