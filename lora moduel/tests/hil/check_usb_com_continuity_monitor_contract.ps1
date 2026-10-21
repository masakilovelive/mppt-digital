[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$monitor = Join-Path $repo 'tools\monitor_usb_com_continuity.ps1'

if (-not (Test-Path -LiteralPath $monitor -PathType Leaf)) {
  throw "Missing USB/COM continuity monitor: $monitor"
}

$source = Get-Content -Raw -LiteralPath $monitor
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $monitor, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
  throw "Monitor parse failed: $($parseErrors[0].Message)"
}

function Assert-SourceContains {
  param([string]$Pattern, [string]$Description)
  if ($source -notmatch $Pattern) {
    throw "Monitor contract missing: $Description"
  }
}

foreach ($expected in @(
    @('USB\\VID_303A&PID_1001&MI_00\\7&7131F6A&0&0000',
      'exact Vehicle PNP identity'),
    @('USB\\VID_303A&PID_1001&MI_00\\7&2159A644&0&0000',
      'exact Ground PNP identity'),
    @("\[string\]\`$VehiclePort\s*=\s*'COM3'", 'Vehicle COM3'),
    @("\[string\]\`$GroundPort\s*=\s*'COM6'", 'Ground COM6'),
    @('CM_Locate_DevNodeW', 'exact Config Manager presence query'),
    @('CM_Get_DevNode_Status', 'Config Manager status/problem query'),
    @('CM_Get_DevNode_PropertyW', 'Config Manager device property query'),
    @('83da6326-97a6-4088-9453-a1923f573b29',
      'DEVPKEY_Device property-set GUID'),
    @('LastArrivalDate[\s\S]{0,240}(102|0x66)',
      'DEVPKEY_Device_LastArrivalDate property id'),
    @('HARDWARE\\DEVICEMAP\\SERIALCOMM',
      'read-only live COM map'),
    @('FileOptions\]::WriteThrough', 'write-through evidence stream'),
    @('Flush\(\$true\)', 'durable record flush'),
    @('startup_metadata\.json', 'immutable startup metadata artifact'),
    @('monitor_source_sha256', 'evidence is bound to the monitor source'),
    @('events\.jsonl', 'durable event stream'),
    @('monitor_ready\.json', 'startup readiness marker'),
    @('summary\.json', 'final monitor summary'),
    @('powercfg\.exe', 'read-only powercfg capture'),
    @('stdout_utf8_base64', 'JSON-safe immutable powercfg stdout'),
    @('stderr_utf8_base64', 'JSON-safe immutable powercfg stderr'),
    @('\[Convert\]::ToBase64String', 'locale-safe powercfg evidence encoding'),
    @('/GETACTIVESCHEME', 'active power scheme query'),
    @('/QH', 'hidden USB power-setting query'),
    @('2a737441-1930-4402-8d77-b2bebba308a3', 'USB subgroup GUID'),
    @('48e6b7a6-50f5-4782-a5d4-53bb8f07e226',
      'USB selective-suspend setting GUID'),
    @('d4e98f31-5ffe-4ce1-be31-1b38b384c009',
      'USB3 Link Power Management setting GUID'),
    @('ValidateRange\(100,\s*60000\)[\s\S]{0,80}\[int\]\$PollIntervalMs\s*=\s*250',
      'bounded low-overhead 250 ms polling default'),
    @('ValidateRange\(1000,\s*60000\)[\s\S]{0,80}\[int\]\$CheckpointIntervalMs\s*=\s*10000',
      'durable checkpoint no faster than one second'),
    @('hardware_query_count', 'hardware-query audit counter'),
    @('serial_port_open_count', 'zero COM-open audit counter'),
    @('powercfg_invocation_count', 'powercfg invocation audit counter'),
    @('last_arrival_change_count', 'LastArrival transition summary'),
    @('first_poll_before_ready_ms',
      'startup native-query cost is separated before READY'),
    @('maximum_post_ready_poll_duration_ms',
      'steady-state maximum query cost is reported'),
    @('average_post_ready_poll_duration_ms',
      'steady-state average query cost is reported'),
    @('state_change', 'change-only durable record type'),
    @('modeled_offline', 'explicit disk-only selftest labeling')
  )) {
  Assert-SourceContains -Pattern $expected[0] -Description $expected[1]
}

foreach ($forbidden in @(
    'System\.IO\.Ports\.SerialPort',
    'GetPortNames',
    'Win32_SerialPort',
    'Get-CimInstance',
    'Get-PnpDevice',
    '\.Open\(\)',
    'DiscardInBuffer',
    'DiscardOutBuffer',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'powercfg\.exe[\s\S]{0,80}/(?:SET|CHANGE|DELETE|DUPLICATE|IMPORT|RESTORE)')) {
  if ($source -match $forbidden) {
    throw "Monitor violates read-only/no-COM-open contract: $forbidden"
  }
}

$temporaryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath())
$evidence = Join-Path $temporaryRoot `
    ('vc_usb_continuity_selftest_' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($evidence)

try {
  $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
    'pwsh.exe'
  } else {
    'powershell.exe'
  }
  $output = @(& $shell -NoLogo -NoProfile -ExecutionPolicy Bypass `
      -File $monitor -SelfTest -SelfTestEvidenceDirectory $evidence 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Monitor selftest exit=$LASTEXITCODE output=$($output -join ' | ')"
  }

  $expectedFiles = @(
    'startup_metadata.json',
    'events.jsonl',
    'monitor_ready.json',
    'summary.json',
    'artifact_hashes.json')
  foreach ($name in $expectedFiles) {
    $path = Join-Path $evidence $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path).Length -eq 0) {
      throw "Selftest evidence missing or empty: $name"
    }
  }

  $startupPath = Join-Path $evidence 'startup_metadata.json'
  $eventPath = Join-Path $evidence 'events.jsonl'
  $readyPath = Join-Path $evidence 'monitor_ready.json'
  $summaryPath = Join-Path $evidence 'summary.json'
  $startup = Get-Content -Raw -LiteralPath $startupPath | ConvertFrom-Json
  $ready = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
  $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
  $eventLines = @(Get-Content -LiteralPath $eventPath)
  $events = @($eventLines | ForEach-Object { $_ | ConvertFrom-Json })

  if ($events.Count -lt 6) {
    throw "Selftest must produce start/change/stop evidence; count=$($events.Count)"
  }
  for ($index = 0; $index -lt $events.Count; ++$index) {
    if ([int]$events[$index].sequence -ne $index) {
      throw "JSONL sequence discontinuity at $index"
    }
    if ($index -gt 0 -and
        [double]$events[$index].elapsed_ms -lt
            [double]$events[$index - 1].elapsed_ms) {
      throw "JSONL elapsed time decreased at $index"
    }
  }
  if ([string]$events[0].event -cne 'start' -or
      [string]$events[-1].event -cne 'stop' -or
      @($events | Where-Object { $_.event -ceq 'state_change' }).Count -ne 4) {
    throw 'Selftest event topology must be start + four changes + stop.'
  }

  $startupHash = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $startupPath).Hash
  $monitorHash = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $monitor).Hash
  $eventHash = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $eventPath).Hash
  if (-not [bool]$startup.immutable_after_start -or
      -not [bool]$startup.modeled_offline -or
      [string]$startup.monitor_source_sha256 -cne $monitorHash -or
      [int]$startup.powercfg_invocation_count -ne 0 -or
      [string]$startup.active_power_scheme.guid -cne
          '381b4222-f694-41f0-9685-ff5bb260df2e' -or
      [uint32]$startup.usb_selective_suspend.ac_index_uint32 -ne 1 -or
      [string]$startup.usb_selective_suspend.ac_interpretation -cne 'enabled' -or
      [uint32]$startup.usb3_link_power_management.ac_index_uint32 -ne 2 -or
      [string]$startup.usb3_link_power_management.ac_interpretation -cne
          'moderate_power_savings') {
    throw 'Selftest immutable power metadata is incomplete or incorrect.'
  }
  if ([string]$ready.startup_metadata_sha256 -cne $startupHash -or
      [string]$summary.startup_metadata_sha256 -cne $startupHash -or
      [string]$summary.events_sha256 -cne $eventHash) {
    throw 'Startup/event hashes do not bind the durable artifacts.'
  }

  if ([string]$summary.status -cne 'COMPLETE' -or
      -not [bool]$summary.modeled_offline -or
      [int]$summary.poll_count -ne 6 -or
      [int]$summary.hardware_query_count -ne 0 -or
      [int]$summary.serial_port_open_count -ne 0 -or
      [int]$summary.powercfg_invocation_count -ne 0 -or
      [int]$summary.roles.vehicle.last_arrival_change_count -ne 0 -or
      [int]$summary.roles.ground.last_arrival_change_count -ne 1 -or
      [int]$summary.roles.ground.absent_transition_count -ne 1 -or
      [int]$summary.roles.ground.present_transition_count -ne 1 -or
      [int]$summary.serial_map_anomaly_poll_count -ne 2 -or
      [int]$summary.polling.interval_ms -ne 250 -or
      [int]$summary.polling.post_ready_poll_count -ne 5 -or
      [Math]::Abs([double]$summary.polling.first_poll_before_ready_ms -
          0.05) -gt 0.001 -or
      [Math]::Abs(
          [double]$summary.polling.maximum_post_ready_poll_duration_ms -
          0.06) -gt 0.001 -or
      [Math]::Abs(
          [double]$summary.polling.average_post_ready_poll_duration_ms -
          0.044) -gt 0.001 -or
      [bool]$summary.continuity_preserved) {
    throw 'Selftest summary counters do not prove the modeled loss/rearrival.'
  }
  if ([string]$summary.stop_reason -cne 'selftest_complete' -or
      -not [bool]$summary.no_com_ports_opened) {
    throw 'Selftest did not terminate cleanly under the no-COM-open contract.'
  }

  $hashRows = Get-Content -Raw `
      -LiteralPath (Join-Path $evidence 'artifact_hashes.json') |
      ConvertFrom-Json
  if ([int]$hashRows.Count -ne 4 -or
      @($hashRows | Where-Object {
        $_.file -eq 'artifact_hashes.json' }).Count -ne 0) {
    throw 'Artifact hash manifest must bind the four pre-manifest artifacts.'
  }

  Write-Host (('PASS usb_com_continuity_monitor_contract events={0} ' +
      'polls={1} hardware_queries={2} COM_opens={3}') -f
      $events.Count, $summary.poll_count, $summary.hardware_query_count,
      $summary.serial_port_open_count)
} finally {
  if (Test-Path -LiteralPath $evidence) {
    Remove-Item -LiteralPath $evidence -Recurse -Force
  }
}
