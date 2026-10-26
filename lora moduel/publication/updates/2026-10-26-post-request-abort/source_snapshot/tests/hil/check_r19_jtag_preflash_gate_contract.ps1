[CmdletBinding()]
param(
  [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$testId = 'R19-JTAG-PREFLASH-GATE-CONTRACT-001'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$gatePath = Join-Path $repo 'tools\invoke_r19_jtag_preflash_gate.ps1'

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId`: $Message" }
}

Assert-Contract (Test-Path -LiteralPath $gatePath -PathType Leaf) `
    "missing standalone JTAG pre-flash gate: $gatePath"
$source = Get-Content -LiteralPath $gatePath -Raw
$runtimeStart = $source.LastIndexOf('Initialize-OutputDirectory',
    [StringComparison]::Ordinal)
Assert-Contract ($runtimeStart -ge 0) 'gate runtime entrypoint is missing'
$runtimeSource = $source.Substring($runtimeStart)

foreach ($pattern in @(
    '\[switch\]\$Execute',
    '\[switch\]\$OfflineContractTest',
    'vc-lora-r19-jtag-preflash-gate-v1',
    'COM3',
    'COM6',
    '90:70:69:11:81:A4',
    '1C:DB:D4:5A:83:80',
    'VID_303A&PID_1001&MI_00',
    'VID_303A&PID_1001&MI_02',
    'DEVPKEY_Device_Parent',
    'DEVPKEY_Device_LocationPaths',
    'DEVPKEY_Device_Service',
    'DEVPKEY_Device_ProblemCode',
    'DEVPKEY_Device_DriverInfPath',
    'DEVPKEY_Device_DriverProvider',
    'DEVPKEY_Device_DriverVersion',
    'DEVPKEY_Device_MatchingDeviceId',
    'DEVPKEY_Device_ClassGuid',
    'DeviceInterfaceGUID',
    'pnputil\.exe',
    '/enum-interfaces',
    'WINUSB',
    'libwdi',
    '6\.1\.7600\.16386',
    '0652254D989022A381EB91084C74A08BAF400E510CE6A2FE4C6EC834AE99EADA',
    '80869ad8-c37f-476a-a6b4-ae241c30a473',
    '88BAE032-5A81-49F0-BC3D-A4FF138216D6',
    'FAIL_JTAG_WINUSB_INTERFACE_UNREGISTERED',
    'FAIL_JTAG_WINUSB_DRIVER',
    'PASS_WINUSB_DRIVER_BINDING_PNP_ONLY')) {
  Assert-Contract ($source -match $pattern) `
      "gate lacks required contract pattern: $pattern"
}

Assert-Contract ($source -notmatch 'System\.IO\.Ports|SerialPort|esptool|write_flash|erase_flash') `
    'pre-flash gate must not open COM or invoke firmware mutation tooling'
Assert-Contract ($source -notmatch '\[string\]\$TargetConfig|esp32s3\.cfg') `
    'pre-flash gate must not accept or load a target configuration'
Assert-Contract ($source -notmatch 'Invoke-Expression|\biex\b') `
    'pre-flash gate must not execute constructed command strings'
Assert-Contract ($source -notmatch 'espusbjtag list_devs') `
    'unbound multi-device list_devs crashes on the reviewed Windows backend'
Assert-Contract ($runtimeSource -notmatch
    'transport init|espusbjtag|Invoke-OpenOcd|Invoke-ReaderPreflight|Assert-LiveToolchain|\bPreflight\b') `
    'PnP-only gate must not open OpenOCD or invoke the JTAG reader preflight'
Assert-Contract ($source -notmatch '\$property\.Status') `
    'Get-PnpDeviceProperty results do not expose a Status member on this host'
Assert-Contract ($source -match
    '\$binding\.service\s+-ieq\s*''WINUSB''') `
    'Windows service identity must be compared case-insensitively'
Assert-Contract ($source -notmatch '\$service\s+-cne\s+''WINUSB''') `
    'case-sensitive WinUSB comparison rejects the signed Espressif binding'
Assert-Contract ($source -match
    '\[string\]\$binding\.mi02_status\s+-ceq\s*''OK''') `
    'PnP device status must remain an exact OK requirement'
Assert-Contract ($source -match '\[int\]\$binding\.problem_code\s+-eq\s*0') `
    'PnP ProblemCode=0 requirement must not be relaxed'
Assert-Contract ($source -match
    '(?s)Get-PnpDevice.*DEVPKEY_Device_Parent.*MI_02') `
    'MI_02 must be selected through the exact MI_00 parent identity'
Assert-Contract ($source -match
    '(?s)USBROOT.*USBMI.*Get-PnpPortChain') `
    'PnP-only gate does not derive the current USB port chain'
Assert-Contract ($source -notmatch 'expected_port_chain') `
    'PnP port chains must be observed at runtime, not pinned as role identity'
Assert-Contract ($source -match 'topology_binding' -and
    $source -match '(?s)pnp_port_chain.*Select-Object\s+-Unique') `
    'PnP-only gate does not require distinct runtime port chains'
Assert-Contract ($source -match
    'firmware_install_allowed=\$false' -and
    $source -match 'active_jtag_proven=\$false' -and
    $source -match 'device_opened=\$false' -and
    $source -match 'jtag_clocks_issued=\$false' -and
    $source -match 'tap_reset_issued=\$false') `
    'PnP-only outcome does not explicitly prohibit install and active JTAG claims'

$scenarios = @(
  [pscustomobject]@{
    name='success';exit=1
    status='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY'
    result='PASS'
    steps=@('pnp_inventory','topology_binding','driver_binding',
      'interface_registration')
    vehicleChain='3.2';groundChain='3.4'
  },
  [pscustomobject]@{
    name='topology_change';exit=1
    status='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY'
    result='PASS'
    steps=@('pnp_inventory','topology_binding','driver_binding',
      'interface_registration')
    vehicleChain='4.2';groundChain='4.4'
  },
  [pscustomobject]@{
    name='duplicate_chain';exit=1
    status='FAIL_JTAG_PNP_BINDING'
    result='FAIL'
    steps=@('pnp_inventory','topology_binding')
    vehicleChain='4.2';groundChain='4.2'
  },
  [pscustomobject]@{
    name='winusb_unregistered';exit=1
    status='FAIL_JTAG_WINUSB_INTERFACE_UNREGISTERED'
    result='FAIL'
    steps=@('pnp_inventory','topology_binding','driver_binding',
      'interface_registration')
  },
  [pscustomobject]@{
    name='driver_mismatch';exit=1
    status='FAIL_JTAG_WINUSB_DRIVER'
    result='FAIL'
    steps=@('pnp_inventory','topology_binding','driver_binding')
  }
)

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_jtag_preflash_gate_contract_' +
      [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  foreach ($scenario in $scenarios) {
    $output = Join-Path $tempRoot $scenario.name
    $stdout = Join-Path $tempRoot ($scenario.name + '.stdout.txt')
    $stderr = Join-Path $tempRoot ($scenario.name + '.stderr.txt')
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File',$gatePath,
      '-RepoRoot',$repo,'-OfflineContractTest',
      '-OfflineScenario',$scenario.name,'-OutputDirectory',$output
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    Assert-Contract ($process.ExitCode -eq $scenario.exit) `
        ("scenario {0} exit mismatch: expected={1} actual={2}; stdout={3}; stderr={4}" -f
          $scenario.name,$scenario.exit,$process.ExitCode,
          (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue),
          (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
    $summaryPath = Join-Path $output 'summary.json'
    Assert-Contract (Test-Path -LiteralPath $summaryPath -PathType Leaf) `
        "scenario $($scenario.name) summary is missing"
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Assert-Contract ([string]$summary.schema -ceq
        'vc-lora-r19-jtag-preflash-gate-v1' -and
        [string]$summary.mode -ceq 'OFFLINE_CONTRACT' -and
        [string]$summary.result -ceq $scenario.result -and
        [string]$summary.status -ceq $scenario.status -and
        -not [bool]$summary.hardware_interaction) `
        "scenario $($scenario.name) summary identity/status mismatch"
    Assert-Contract (-not [bool]$summary.safety.com_opened -and
        -not [bool]$summary.safety.flash_written -and
        -not [bool]$summary.safety.target_config_loaded -and
        -not [bool]$summary.safety.target_halt_or_reset_issued -and
        -not [bool]$summary.safety.target_state_modified -and
        -not [bool]$summary.safety.device_opened -and
        -not [bool]$summary.safety.jtag_clocks_issued -and
        -not [bool]$summary.safety.tap_reset_issued -and
        -not [bool]$summary.safety.active_jtag_proven -and
        -not [bool]$summary.safety.firmware_install_allowed -and
        [bool]$summary.fail_closed) `
        "scenario $($scenario.name) violated non-mutating gate safety"
    [string[]]$actualSteps = @($summary.steps | ForEach-Object {
      [string]$_.name
    })
    Assert-Contract (($actualSteps -join ',') -ceq
        (@($scenario.steps) -join ',')) `
        "scenario $($scenario.name) step order mismatch"
    Assert-Contract (@($summary.steps | Where-Object {
          [bool]$_.hardware_interaction
        }).Count -eq 0) `
        "scenario $($scenario.name) offline mock reached hardware"
    if ($null -ne $scenario.PSObject.Properties['vehicleChain']) {
      Assert-Contract (@($summary.roles).Count -eq 2 -and
          [string]$summary.roles[0].pnp_port_chain -ceq
            [string]$scenario.vehicleChain -and
          [string]$summary.roles[1].pnp_port_chain -ceq
            [string]$scenario.groundChain) `
          "scenario $($scenario.name) did not preserve observed port chains"
    }
    if ($scenario.name -in @('success','topology_change')) {
      Assert-Contract (
          [bool]$summary.roles[0].driver_binding_proven -and
          [bool]$summary.roles[1].driver_binding_proven -and
          [bool]$summary.roles[0].interface_registration_proven -and
          [bool]$summary.roles[1].interface_registration_proven -and
          [string]$summary.roles[0].openocd_usb_location -ceq '' -and
          [string]$summary.roles[1].openocd_usb_location -ceq '' -and
          -not [bool]$summary.roles[0].reader_preflight_proven -and
          -not [bool]$summary.roles[1].reader_preflight_proven) `
          "$($scenario.name) did not prove both fixed-identity PnP bindings"
      Assert-Contract ([string]$summary.roles[0].pnp_port_chain -cne
          [string]$summary.roles[1].pnp_port_chain) `
          "$($scenario.name) accepted duplicate role port chains"
    }
    if ($scenario.name -ceq 'duplicate_chain') {
      Assert-Contract (-not [bool]$summary.roles[0].driver_binding_proven -and
          -not [bool]$summary.roles[1].driver_binding_proven -and
          [string]$summary.failure -match 'distinct') `
          'duplicate role port chains did not fail closed before driver proof'
    }
  }
  Write-Output "$testId PASS"
} finally {
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($tempRoot.StartsWith($tempPrefix,
        [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $tempRoot) -match
        '^vc_lora_r19_jtag_preflash_gate_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
