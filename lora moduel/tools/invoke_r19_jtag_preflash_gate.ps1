[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory = '',
  [switch]$Execute,
  [switch]$OfflineContractTest,
  [ValidateSet('success','topology_change','duplicate_chain',
      'winusb_unregistered','driver_mismatch')]
  [string]$OfflineScenario = 'success',
  [string]$ReaderPath = '',
  [string]$ReaderSha256 = '',
  [string]$OpenOcdExecutable = '',
  [string]$OpenOcdSha256 = '',
  [string]$InterfaceConfig = '',
  [string]$InterfaceConfigSha256 = '',
  [string]$ScriptsRoot = '',
  [string]$ScriptsTreeSha256 = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$schema = 'vc-lora-r19-jtag-preflash-gate-v1'
$testId = 'R19-JTAG-PREFLASH-GATE-001'
$expectedDriverProvider = 'libwdi'
$expectedDriverVersion = '6.1.7600.16386'
$expectedDriverInfSha256 =
    '0652254D989022A381EB91084C74A08BAF400E510CE6A2FE4C6EC834AE99EADA'
$expectedMatchingDeviceId = 'USB\VID_303A&PID_1001&MI_02'
$expectedDeviceClassGuid = '{88BAE032-5A81-49F0-BC3D-A4FF138216D6}'
$expectedInterfaceGuid = '{80869ad8-c37f-476a-a6b4-ae241c30a473}'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReaderPath)) {
  $ReaderPath = Join-Path $repo 'tools\read_r19_runtime_stage_jtag.ps1'
}
$roleDefinitions = @(
  [pscustomobject][ordered]@{
    role='vehicle';com='COM3';serial='90:70:69:11:81:A4'
    parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
  },
  [pscustomobject][ordered]@{
    role='ground';com='COM6';serial='1C:DB:D4:5A:83:80'
    parent='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
  }
)
$startedUtc = [DateTime]::UtcNow.ToString('o')
$steps = [Collections.ArrayList]::new()
$roles = [Collections.ArrayList]::new()
$terminalStatus = 'FAIL_JTAG_PNP_ONLY_INTERNAL'
$failure = ''
$hardwareInteraction = $false
$toolchainEvidence = $null

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Stop-Gate([string]$Status, [string]$Message) {
  $script:terminalStatus = $Status
  throw $Message
}

function Get-Sha256([string]$LiteralPath) {
  (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 `
      -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Initialize-OutputDirectory {
  if ([string]::IsNullOrWhiteSpace($script:OutputDirectory)) {
    $base = Join-Path $repo "runs\hil\$testId"
    [void][IO.Directory]::CreateDirectory($base)
    $script:OutputDirectory = Join-Path $base `
        ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
          [Guid]::NewGuid().ToString('N').Substring(0,8))
  }
  $full = [IO.Path]::GetFullPath($script:OutputDirectory)
  [void][IO.Directory]::CreateDirectory($full)
  $script:OutputDirectory = (Resolve-Path -LiteralPath $full).Path.TrimEnd('\')
}

function Write-Text([string]$LiteralPath, [string]$Text) {
  [IO.File]::WriteAllText($LiteralPath,$Text,$utf8)
}

function Write-Summary([object]$Value) {
  $path = Join-Path $OutputDirectory 'summary.json'
  Write-Text $path (($Value | ConvertTo-Json -Depth 32) + $newline)
}

function Add-Step([string]$Name, [string]$Result,
    [bool]$StepHardwareInteraction, [object]$Evidence) {
  [void]$steps.Add([pscustomobject][ordered]@{
    name=$Name;result=$Result
    hardware_interaction=$StepHardwareInteraction;evidence=$Evidence
  })
}

function Get-PropertyData([string]$InstanceId, [string]$KeyName,
    [string]$ExpectedType) {
  $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
      -KeyName $KeyName -ErrorAction Stop
  if ($null-eq$property -or
      [string]$property.KeyName -cne $KeyName -or
      [string]$property.Type -cne $ExpectedType -or
      $null-eq$property.PSObject.Properties['Data'] -or
      $null-eq$property.Data) {
    throw "PnP property identity, type, or data is invalid: $KeyName for $InstanceId"
  }
  $property.Data
}

function Get-PnpPortChain([object[]]$LocationPaths) {
  [Collections.Generic.List[string]]$chains = @()
  foreach ($pathValue in @($LocationPaths)) {
    $path = [string]$pathValue
    if ($path -notmatch 'USBROOT\(\d+\).*#USBMI\(2\)$') {continue}
    $portMatches = [regex]::Matches($path,'#USB\((?<port>\d+)\)')
    if ($portMatches.Count -lt 1) {continue}
    $ports = @($portMatches | ForEach-Object {$_.Groups['port'].Value})
    $chain = $ports -join '.'
    if (-not $chains.Contains($chain)) {[void]$chains.Add($chain)}
  }
  if ($chains.Count -ne 1) {
    throw 'MI_02 must expose exactly one unambiguous USBROOT-to-USBMI port chain'
  }
  $chains[0]
}

function Get-LiveRoleBindings {
  $allPresent = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
  [Collections.ArrayList]$bindings = @()
  foreach ($definition in $roleDefinitions) {
    $comPattern = '\(' + [regex]::Escape([string]$definition.com) + '\)$'
    $comMatches = @($allPresent | Where-Object {
      [string]$_.InstanceId -imatch
        '^USB\\VID_303A&PID_1001&MI_00\\' -and
      [string]$_.FriendlyName -match $comPattern
    })
    if ($comMatches.Count -ne 1) {
      Stop-Gate 'FAIL_JTAG_PNP_BINDING' `
          "$($definition.role) $($definition.com) MI_00 is not unique"
    }
    $comDevice = $comMatches[0]
    $parent = [string](Get-PropertyData $comDevice.InstanceId `
        'DEVPKEY_Device_Parent' 'String')
    if ($parent -cne [string]$definition.parent) {
      Stop-Gate 'FAIL_JTAG_PNP_BINDING' `
          "$($definition.role) MI_00 parent MAC does not match the fixed role"
    }
    $jtagMatches = @($allPresent | Where-Object {
      if ([string]$_.InstanceId -inotmatch
          '^USB\\VID_303A&PID_1001&MI_02\\') {return $false}
      try {
        [string](Get-PropertyData $_.InstanceId 'DEVPKEY_Device_Parent' `
            'String') `
            -ceq $parent
      } catch {$false}
    })
    if ($jtagMatches.Count -ne 1) {
      Stop-Gate 'FAIL_JTAG_PNP_BINDING' `
          "$($definition.role) same-parent MI_02 is not unique"
    }
    $jtag = $jtagMatches[0]
    $service = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_Service' 'String')
    $problemCode = [int](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_ProblemCode' 'UInt32')
    $driverInf = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_DriverInfPath' 'String')
    $driverProvider = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_DriverProvider' 'String')
    $driverVersion = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_DriverVersion' 'String')
    $matchingDeviceId = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_MatchingDeviceId' 'String')
    $deviceClassGuid = [string](Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_ClassGuid' 'Guid')
    $driverInfPath = Join-Path (Join-Path $env:SystemRoot 'INF') $driverInf
    try {$driverInfSha256 = Get-Sha256 $driverInfPath} catch {
      Stop-Gate 'FAIL_JTAG_WINUSB_DRIVER' `
          "$($definition.role) installed driver INF cannot be hashed"
    }
    $locationPaths = @(Get-PropertyData $jtag.InstanceId `
        'DEVPKEY_Device_LocationPaths' 'StringList')
    try {$portChain = Get-PnpPortChain $locationPaths} catch {
      Stop-Gate 'FAIL_JTAG_PNP_BINDING' $_.Exception.Message
    }
    [void]$bindings.Add([pscustomobject][ordered]@{
      role=[string]$definition.role;com=[string]$definition.com
      serial=[string]$definition.serial;parent=$parent
      mi00_instance_id=[string]$comDevice.InstanceId
      mi02_instance_id=[string]$jtag.InstanceId
      mi02_status=[string]$jtag.Status;service=$service
      problem_code=$problemCode;driver_inf=$driverInf
      driver_inf_sha256=$driverInfSha256;driver_provider=$driverProvider
      driver_version=$driverVersion;matching_device_id=$matchingDeviceId
      device_class_guid=$deviceClassGuid;location_paths=@($locationPaths)
      pnp_port_chain=$portChain
      registry_interface_guids=@();pnputil_interfaces=@()
      driver_binding_proven=$false;interface_registration_proven=$false
      openocd_usb_location='';reader_preflight_proven=$false
      reader_summary_path='';reader_summary_sha256=''
    })
  }
  @($bindings)
}

function Get-OfflineRoleBindings {
  @($roleDefinitions | ForEach-Object {
    $leaf = if($_.role-ceq'vehicle'){'7&7131F6A&0&0000'}else{
      '7&2159A644&0&0000'}
    $jtagLeaf = $leaf.Substring(0,$leaf.Length-1) + '2'
    $rootPort=if($OfflineScenario-in@('topology_change','duplicate_chain')){
      4}else{3}
    $leafPort=if($_.role-ceq'vehicle'-or
        $OfflineScenario-ceq'duplicate_chain'){2}else{4}
    $locationPath=('PCIROOT(0)#USBROOT(0)#USB({0})#USB({1})#USBMI(2)' -f
      $rootPort,$leafPort)
    $portChain=Get-PnpPortChain @($locationPath)
    [pscustomobject][ordered]@{
      role=[string]$_.role;com=[string]$_.com;serial=[string]$_.serial
      parent=[string]$_.parent
      mi00_instance_id=('USB\VID_303A&PID_1001&MI_00\' + $leaf)
      mi02_instance_id=('USB\VID_303A&PID_1001&MI_02\' + $jtagLeaf)
      mi02_status='OK';service='WINUSB';problem_code=0
      driver_inf='oem227.inf'
      driver_inf_sha256=$expectedDriverInfSha256
      driver_provider=$expectedDriverProvider
      driver_version=$expectedDriverVersion
      matching_device_id=$expectedMatchingDeviceId
      device_class_guid=$expectedDeviceClassGuid
      location_paths=@($locationPath)
      pnp_port_chain=$portChain
      registry_interface_guids=@($expectedInterfaceGuid)
      pnputil_interfaces=@('\\?\USB#VID_303A&PID_1001&MI_02#offline#' +
        $expectedInterfaceGuid)
      driver_binding_proven=$false;interface_registration_proven=$false
      openocd_usb_location='';reader_preflight_proven=$false
      reader_summary_path='';reader_summary_sha256=''
    }
  })
}

function Get-RegistryInterfaceGuids([string]$InstanceId) {
  [Collections.Generic.List[string]]$values = @()
  $keyPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' +
      $InstanceId + '\Device Parameters'
  try {
    $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
    foreach ($name in @('DeviceInterfaceGUID','DeviceInterfaceGUIDs')) {
      $value = $key.GetValue($name,$null,
          [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      foreach ($entry in @($value)) {
        $text = [string]$entry
        if ($text -match '^\{[0-9A-Fa-f-]{36}\}$' -and
            -not $values.Contains($text)) {[void]$values.Add($text)}
      }
    }
  } catch {}
  @($values)
}

function Get-PnpUtilInterfaces([string]$InstanceId, [string]$Role) {
  $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
  Assert-Condition (Test-Path -LiteralPath $pnputil -PathType Leaf) `
      'pnputil.exe is unavailable'
  $text = (& $pnputil /enum-interfaces /enabled /instanceid $InstanceId `
      /format xml 2>&1 | Out-String)
  $exitCode = $LASTEXITCODE
  Write-Text (Join-Path $OutputDirectory `
      ("pnputil-{0}-interfaces.xml" -f $Role)) $text
  if ($exitCode -ne 0) {return @()}
  try {$xml = [xml]$text} catch {return @()}
  [Collections.Generic.List[string]]$paths = @()
  foreach ($node in @($xml.SelectNodes('/PnpUtil/Interface'))) {
    if ([string]$node.DeviceInstanceId -ieq $InstanceId -and
        [string]$node.Status -ieq 'Enabled') {
      [void]$paths.Add([string]$node.Path)
    }
  }
  @($paths)
}

function Assert-InterfaceRegistration([object[]]$Bindings) {
  foreach ($binding in $Bindings) {
    if ($OfflineContractTest.IsPresent) {
      $binding.interface_registration_proven=$true
      if ($OfflineScenario -ceq 'winusb_unregistered' -and
          [string]$binding.role -ceq 'vehicle') {
        $binding.registry_interface_guids=@()
        $binding.pnputil_interfaces=@()
        $binding.interface_registration_proven=$false
      }
    } else {
      $binding.registry_interface_guids = @(
        Get-RegistryInterfaceGuids $binding.mi02_instance_id)
      $binding.pnputil_interfaces = @(
        Get-PnpUtilInterfaces $binding.mi02_instance_id $binding.role)
      $registered=@($binding.registry_interface_guids|Where-Object{
        [string]$_-ieq$expectedInterfaceGuid})
      $enabled=@($binding.pnputil_interfaces|Where-Object{
        [string]$_-imatch('#'+[regex]::Escape($expectedInterfaceGuid)+'$')})
      $binding.interface_registration_proven =
          ($registered.Count-eq1-and$enabled.Count-eq1)
    }
  }
}

function Assert-DriverBindings([object[]]$Bindings) {
  foreach($binding in $Bindings){
    if($OfflineContractTest.IsPresent-and
        $OfflineScenario-ceq'driver_mismatch'-and
        [string]$binding.role-ceq'vehicle'){
      $binding.driver_inf_sha256=('0'*64)
    }
    $binding.driver_binding_proven=(
      [string]$binding.mi02_status -ceq 'OK' -and
      [string]$binding.service -ieq 'WINUSB' -and
      [int]$binding.problem_code -eq 0 -and
      [string]$binding.driver_provider -ieq $expectedDriverProvider -and
      [string]$binding.driver_version -ceq $expectedDriverVersion -and
      [string]$binding.driver_inf_sha256 -ceq $expectedDriverInfSha256 -and
      [string]$binding.matching_device_id -ieq $expectedMatchingDeviceId -and
      [string]$binding.device_class_guid -ieq $expectedDeviceClassGuid)
  }
}

function Assert-LiveToolchain {
  foreach ($name in @('ReaderPath','ReaderSha256','OpenOcdExecutable',
      'OpenOcdSha256','InterfaceConfig','InterfaceConfigSha256',
      'ScriptsRoot','ScriptsTreeSha256')) {
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-Variable -Name $name -ValueOnly))) {
      Stop-Gate 'FAIL_JTAG_TOOLCHAIN_PIN' "missing live parameter: -$name"
    }
  }
  try {
    $script:ReaderPath=(Resolve-Path -LiteralPath $ReaderPath `
        -ErrorAction Stop).Path
    $script:OpenOcdExecutable=(Resolve-Path -LiteralPath $OpenOcdExecutable `
        -ErrorAction Stop).Path
    $script:InterfaceConfig=(Resolve-Path -LiteralPath $InterfaceConfig `
        -ErrorAction Stop).Path
    $script:ScriptsRoot=(Resolve-Path -LiteralPath $ScriptsRoot `
        -ErrorAction Stop).Path
    $trustedReader=(Resolve-Path -LiteralPath (Join-Path $repo `
        'tools\read_r19_runtime_stage_jtag.ps1') -ErrorAction Stop).Path
    $trustedOpenOcd=(Resolve-Path -LiteralPath $pinnedOpenOcdPath `
        -ErrorAction Stop).Path
    $trustedInterface=(Resolve-Path -LiteralPath $pinnedInterfacePath `
        -ErrorAction Stop).Path
    $trustedScripts=(Resolve-Path -LiteralPath $pinnedScriptsRoot `
        -ErrorAction Stop).Path
    Assert-Condition ($ReaderPath.Equals($trustedReader,
        [StringComparison]::OrdinalIgnoreCase)) `
        'JTAG reader path is not the reviewed repository tool'
    Assert-Condition ($OpenOcdExecutable.Equals($trustedOpenOcd,
        [StringComparison]::OrdinalIgnoreCase)) `
        'OpenOCD path is not the reviewed pinned tool'
    Assert-Condition ($InterfaceConfig.Equals($trustedInterface,
        [StringComparison]::OrdinalIgnoreCase)) `
        'OpenOCD interface config path is not reviewed'
    Assert-Condition ($ScriptsRoot.Equals($trustedScripts,
        [StringComparison]::OrdinalIgnoreCase)) `
        'OpenOCD scripts path is not reviewed'
    Assert-Condition ($ReaderSha256.ToUpperInvariant() -ceq
        $pinnedReaderSha256 -and (Get-Sha256 $ReaderPath) -ceq
        $pinnedReaderSha256) 'JTAG reader hash differs from the reviewed pin'
    Assert-Condition ($OpenOcdSha256.ToUpperInvariant() -ceq
        $pinnedOpenOcdSha256 -and (Get-Sha256 $OpenOcdExecutable) -ceq
        $pinnedOpenOcdSha256) 'OpenOCD executable hash mismatch'
    Assert-Condition ($InterfaceConfigSha256.ToUpperInvariant() -ceq
        $pinnedInterfaceConfigSha256 -and (Get-Sha256 $InterfaceConfig) -ceq
        $pinnedInterfaceConfigSha256) 'OpenOCD interface hash mismatch'
    Assert-Condition ($ScriptsTreeSha256.ToUpperInvariant() -ceq
        $pinnedScriptsTreeSha256 -and
        (Get-DirectoryTreeSha256 $ScriptsRoot) -ceq
          $pinnedScriptsTreeSha256) 'OpenOCD scripts tree hash mismatch'
  } catch {
    Stop-Gate 'FAIL_JTAG_TOOLCHAIN_PIN' $_.Exception.Message
  }
}

function Convert-ArgumentForStartProcess([string]$Value) {
  if ($Value -notmatch '[\s"]') {return $Value}
  '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}

function Invoke-NativeCapture([string]$Name, [string]$Executable,
    [string[]]$Arguments, [int]$TimeoutMilliseconds) {
  $stdoutPath=Join-Path $OutputDirectory ($Name+'.stdout.log')
  $stderrPath=Join-Path $OutputDirectory ($Name+'.stderr.log')
  $process=[Diagnostics.Process]::new()
  $process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
  $process.StartInfo.FileName=$Executable
  $process.StartInfo.Arguments=(@($Arguments|ForEach-Object{
    Convert-ArgumentForStartProcess ([string]$_)})-join' ')
  $process.StartInfo.UseShellExecute=$false
  $process.StartInfo.CreateNoWindow=$true
  $process.StartInfo.RedirectStandardOutput=$true
  $process.StartInfo.RedirectStandardError=$true
  $stdoutTask=$null;$stderrTask=$null;$stdout='';$stderr=''
  $exitCode=255;$timedOut=$false;$terminationProven=$false
  try {
    Assert-Condition ($process.Start()) "$Name process did not start"
    $stdoutTask=$process.StandardOutput.ReadToEndAsync()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    if(-not$process.WaitForExit($TimeoutMilliseconds)){
      $timedOut=$true
      $taskkill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
      & $taskkill /PID $process.Id /T /F 1>$null 2>$null
      $terminationProven=$process.WaitForExit(10000)
      $exitCode=124
    }else{
      $process.WaitForExit();$process.Refresh()
      $exitCode=[int]$process.ExitCode;$terminationProven=$true
    }
  } finally {
    if($null-ne$stdoutTask){try{$stdout=$stdoutTask.GetAwaiter().GetResult()}catch{}}
    if($null-ne$stderrTask){try{$stderr=$stderrTask.GetAwaiter().GetResult()}catch{}}
    $process.Dispose()
    Write-Text $stdoutPath $stdout;Write-Text $stderrPath $stderr
  }
  [pscustomobject][ordered]@{exit_code=$exitCode;timed_out=$timedOut
    termination_proven=$terminationProven;stdout=$stdout;stderr=$stderr
    stdout_path=$stdoutPath;stderr_path=$stderrPath}
}

function Invoke-OpenOcdRoleDiscovery([object]$Binding) {
  $role=[string]$Binding.role
  $serial=[string]$Binding.serial
  $arguments=@('-s',$ScriptsRoot,'-f',$InterfaceConfig,
    '-c','noinit',
    '-c',('adapter serial '+$serial),
    '-c','echo VC_LORA_JTAG_DISCOVERY_POLICY=SERIAL_BOUND_NO_TARGET_NO_RESET_NO_HALT',
    '-c','transport init',
    '-c','set vc_lora_serial [espusbjtag get_serial]; echo VC_LORA_JTAG_DISCOVERY_SERIAL=$vc_lora_serial',
    '-c','set vc_lora_location [espusbjtag get_location]; echo VC_LORA_JTAG_DISCOVERY_LOCATION=$vc_lora_location',
    '-c','echo VC_LORA_JTAG_DISCOVERY_OPEN',
    '-c','shutdown')
  $native=Invoke-NativeCapture ('openocd-discovery-'+$role) `
      $OpenOcdExecutable $arguments 20000
  $combined=[string]$native.stdout+$newline+[string]$native.stderr
  $serialMatches=@([regex]::Matches($combined,
      '(?m)^VC_LORA_JTAG_DISCOVERY_SERIAL=(?<value>[^\r\n]+)\r?$'))
  $locationMatches=@([regex]::Matches($combined,
      '(?m)^VC_LORA_JTAG_DISCOVERY_LOCATION=(?<value>\d{1,3}-\d{1,3}(?:\.\d{1,3})*)\r?$'))
  $openedSerial=if($serialMatches.Count-eq1){
    $serialMatches[0].Groups['value'].Value}else{''}
  $openedLocation=if($locationMatches.Count-eq1){
    $locationMatches[0].Groups['value'].Value}else{''}
  $openMarker=[regex]::Matches($combined,
      '(?m)^VC_LORA_JTAG_DISCOVERY_OPEN\r?$').Count-eq1
  $shutdownProven=$combined-match'(?im)^shutdown command invoked\r?$'
  $identityProven=($serialMatches.Count-eq1-and
    $locationMatches.Count-eq1-and
    $openedSerial.Equals($serial,[StringComparison]::OrdinalIgnoreCase))
  $proven=([int]$native.exit_code-eq0-and-not[bool]$native.timed_out-and
    [bool]$native.termination_proven-and$identityProven-and$openMarker-and
    $shutdownProven)
  [pscustomobject][ordered]@{role=$role;expected_serial=$serial
    opened_serial=$openedSerial;opened_location=$openedLocation
    proven=[bool]$proven;open_marker_proven=[bool]$openMarker
    shutdown_proven=[bool]$shutdownProven;exit_code=[int]$native.exit_code
    timed_out=[bool]$native.timed_out
    termination_proven=[bool]$native.termination_proven
    command=$arguments;target_config_loaded=$false
    stdout_path=$native.stdout_path;stderr_path=$native.stderr_path}
}

function Invoke-OpenOcdList([object[]]$Bindings) {
  if ($OfflineContractTest.IsPresent) {
    $locations=if($OfflineScenario-ceq'location_missing'){
      @('1-3.2')}else{@('1-3.2','1-3.4')}
    $discoveries=@($Bindings|ForEach-Object{
      $suffix=[regex]::Escape([string]$_.pnp_port_chain)
      $matches=@($locations|Where-Object{[string]$_-match
          ('^\d{1,3}-'+$suffix+'$')})
      $location=if($matches.Count-eq1){[string]$matches[0]}else{''}
      [pscustomobject][ordered]@{role=[string]$_.role
        expected_serial=[string]$_.serial;opened_serial=[string]$_.serial
        opened_location=$location;proven=($location-ne'')
        open_marker_proven=($location-ne'');shutdown_proven=$true
        exit_code=if($location-ne''){0}else{1};timed_out=$false
        termination_proven=$true;command=@('offline-serial-bound')
        target_config_loaded=$false;stdout_path='';stderr_path=''}
    })
    return [pscustomobject][ordered]@{method='serial_bound_discovery'
      exit_code=if(@($discoveries|Where-Object{-not$_.proven}).Count){1}else{0}
      timed_out=$false;termination_proven=$true;locations=$locations
      discoveries=$discoveries;commands=@($discoveries|ForEach-Object{$_.command})
      target_config_loaded=$false}
  }
  $discoveries=@($Bindings|ForEach-Object{Invoke-OpenOcdRoleDiscovery $_})
  [Collections.Generic.List[string]]$locations=@()
  foreach($discovery in $discoveries){
    $location=[string]$discovery.opened_location
    if(-not[string]::IsNullOrWhiteSpace($location)-and
        -not$locations.Contains($location)){[void]$locations.Add($location)}
  }
  $firstFailed=@($discoveries|Where-Object{-not[bool]$_.proven}|Select-Object -First 1)
  [pscustomobject][ordered]@{method='serial_bound_discovery'
    exit_code=if($firstFailed.Count){
      if([int]$firstFailed[0].exit_code-ne0){[int]$firstFailed[0].exit_code}else{1}
    }else{0}
    timed_out=(@($discoveries|Where-Object{[bool]$_.timed_out}).Count-gt0)
    termination_proven=(@($discoveries|Where-Object{
      -not[bool]$_.termination_proven}).Count-eq0)
    locations=@($locations);discoveries=$discoveries
    commands=@($discoveries|ForEach-Object{$_.command})
    target_config_loaded=$false}
}

function Bind-OpenOcdLocations([object[]]$Bindings, [object]$ListEvidence) {
  if ([int]$ListEvidence.exit_code -ne 0 -or
      [bool]$ListEvidence.timed_out -or
      -not [bool]$ListEvidence.termination_proven) {
    Stop-Gate 'FAIL_JTAG_LOCATION_DISCOVERY' `
        'serial-bound OpenOCD discovery did not complete successfully'
  }
  foreach($binding in $Bindings){
    $matches=@($ListEvidence.discoveries|Where-Object{
      [string]$_.role-ceq[string]$binding.role})
    if($matches.Count-ne1-or-not[bool]$matches[0].proven){
      Stop-Gate 'FAIL_JTAG_LOCATION_DISCOVERY' `
          "$($binding.role) serial-bound OpenOCD discovery is unproven"
    }
    $discovery=$matches[0]
    if(-not([string]$discovery.opened_serial).Equals(
        [string]$binding.serial,[StringComparison]::OrdinalIgnoreCase)){
      Stop-Gate 'FAIL_JTAG_LOCATION_DISCOVERY' `
          "$($binding.role) OpenOCD serial does not match the fixed role"
    }
    $escaped=[regex]::Escape([string]$binding.pnp_port_chain)
    $location=[string]$discovery.opened_location
    if($location-notmatch('^\d{1,3}-'+$escaped+'$')){
      Stop-Gate 'FAIL_JTAG_LOCATION_DISCOVERY' `
          "$($binding.role) OpenOCD location does not match the PnP port chain"
    }
    $binding.openocd_usb_location=$location
  }
  if([string]$Bindings[0].openocd_usb_location -ceq
      [string]$Bindings[1].openocd_usb_location){
    Stop-Gate 'FAIL_JTAG_LOCATION_DISCOVERY' `
        'Vehicle and Ground resolved to the same OpenOCD USB location'
  }
}

function Get-PowerShellExecutable {
  $path=Join-Path $PSHOME 'powershell.exe'
  Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) `
      'Windows PowerShell executable is unavailable'
  (Resolve-Path -LiteralPath $path).Path
}

function Invoke-ReaderPreflight([object]$Binding) {
  if($OfflineContractTest.IsPresent){
    $failed=(($OfflineScenario-ceq'vehicle_reader_failure'-and
        [string]$Binding.role-ceq'vehicle')-or
      ($OfflineScenario-ceq'ground_reader_failure'-and
        [string]$Binding.role-ceq'ground'))
    return [pscustomobject][ordered]@{proven=(-not$failed)
      exit_code=if($failed){1}else{0};summary_path='';summary_sha256=''
      termination_proven=$true;hardware_interaction=$false}
  }
  $roleOutput=Join-Path $OutputDirectory `
      ('reader-preflight-'+[string]$Binding.role)
  [void][IO.Directory]::CreateDirectory($roleOutput)
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ReaderPath,
    '-Execute','-Preflight','-Role',[string]$Binding.role,
    '-ProbeSerial',[string]$Binding.serial,
    '-ProbeUsbLocation',[string]$Binding.openocd_usb_location,
    '-OpenOcdExecutable',$OpenOcdExecutable,
    '-OpenOcdSha256',$OpenOcdSha256,
    '-InterfaceConfig',$InterfaceConfig,
    '-InterfaceConfigSha256',$InterfaceConfigSha256,
    '-ScriptsRoot',$ScriptsRoot,'-OutputRoot',$roleOutput)
  $native=Invoke-NativeCapture `
      ('reader-preflight-'+[string]$Binding.role) `
      (Get-PowerShellExecutable) $arguments 60000
  $summaryPath=Join-Path $roleOutput 'summary.json'
  $summary=$null
  if(Test-Path -LiteralPath $summaryPath -PathType Leaf){
    try{$summary=[IO.File]::ReadAllText($summaryPath,$utf8)|ConvertFrom-Json}
    catch{$summary=$null}
  }
  $proven=$false
  if($null-ne$summary){
    try{
      $proven=([int]$native.exit_code-eq0-and
        -not[bool]$native.timed_out-and[bool]$native.termination_proven-and
        [string]$summary.schema-ceq'vc-lora-r19-jtag-preflight-v1'-and
        [string]$summary.result-ceq'PASS'-and
        [string]$summary.status-ceq'PASS_JTAG_PREFLIGHT_NO_RESET_NO_HALT'-and
        [string]$summary.mode-ceq'live-jtag-preflight'-and
        [bool]$summary.hardware_interaction-and
        [string]$summary.binding.role-ceq[string]$Binding.role-and
        [string]$summary.binding.requested_serial-ieq[string]$Binding.serial-and
        [string]$summary.binding.opened_serial-ieq[string]$Binding.serial-and
        [string]$summary.binding.requested_usb_location-ceq
          [string]$Binding.openocd_usb_location-and
        [string]$summary.binding.opened_usb_location-ceq
          [string]$Binding.openocd_usb_location-and
        -not[bool]$summary.safety.com_opened-and
        -not[bool]$summary.safety.flash_written-and
        -not[bool]$summary.safety.target_config_loaded-and
        -not[bool]$summary.safety.target_halt_or_reset_issued-and
        -not[bool]$summary.safety.target_state_modified-and
        [bool]$summary.safety.process_termination_proven-and
        [bool]$summary.safety.shutdown_proven)
    }catch{$proven=$false}
  }
  [pscustomobject][ordered]@{proven=$proven
    exit_code=[int]$native.exit_code;summary_path=if($null-ne$summary){
      $summaryPath}else{''};summary_sha256=if($null-ne$summary){
      Get-Sha256 $summaryPath}else{''}
    termination_proven=[bool]$native.termination_proven
    hardware_interaction=$true}
}

Initialize-OutputDirectory
try {
  Assert-Condition (-not($Execute.IsPresent-and$OfflineContractTest.IsPresent)) `
      'Execute and OfflineContractTest are mutually exclusive'
  Assert-Condition ($Execute.IsPresent-or$OfflineContractTest.IsPresent) `
      'Choose -OfflineContractTest or explicitly supply -Execute'
  if(-not$OfflineContractTest.IsPresent){
    $toolchainEvidence=[pscustomobject][ordered]@{
      policy='PNP_ONLY_OPENOCD_AND_READER_NOT_INVOKED'
      legacy_parameters_accepted=$true
      openocd_invoked=$false;reader_invoked=$false
    }
    $boundRoles=@(Get-LiveRoleBindings)
  }else{
    $toolchainEvidence=[pscustomobject][ordered]@{
      policy='PNP_ONLY_OPENOCD_AND_READER_NOT_INVOKED'
      legacy_parameters_accepted=$true
      openocd_invoked=$false;reader_invoked=$false
    }
    $boundRoles=@(Get-OfflineRoleBindings)
  }
  foreach($binding in $boundRoles){[void]$roles.Add($binding)}
  if($roles.Count-ne2){
    Stop-Gate 'FAIL_JTAG_PNP_BINDING' 'Exactly two fixed roles are required'
  }
  Add-Step 'pnp_inventory' 'PASS' $false `
      ([pscustomobject]@{role_count=$roles.Count
        mapping='fixed COM MI_00 -> exact parent MAC -> same-parent MI_02'})

  $portChains=@($roles|ForEach-Object{[string]$_.pnp_port_chain})
  $validPortChains=@($portChains|Where-Object{
    $_-match '^\d+(?:\.\d+)*$'})
  $distinctPortChains=@($portChains|Select-Object -Unique)
  $topologyProven=($validPortChains.Count-eq2-and
      $distinctPortChains.Count-eq2)
  Add-Step 'topology_binding' $(if($topologyProven){'PASS'}else{'FAIL'}) `
      $false ([pscustomobject]@{policy=(
        'each role has one observed chain; Vehicle and Ground are distinct')
        roles=@($roles|ForEach-Object{
          [pscustomobject]@{role=$_.role;pnp_port_chain=$_.pnp_port_chain}})})
  if(-not$topologyProven){
    Stop-Gate 'FAIL_JTAG_PNP_BINDING' `
        'Vehicle and Ground must have distinct unambiguous PnP port chains'
  }

  Assert-DriverBindings @($roles)
  $driverFailures=@($roles|Where-Object{-not$_.driver_binding_proven})
  Add-Step 'driver_binding' $(if($driverFailures.Count){'FAIL'}else{'PASS'}) `
      $false ([pscustomobject]@{roles=@($roles|ForEach-Object{
        [pscustomobject]@{role=$_.role;proven=[bool]$_.driver_binding_proven
          service=$_.service;problem_code=$_.problem_code
          driver_provider=$_.driver_provider;driver_version=$_.driver_version
          driver_inf=$_.driver_inf;driver_inf_sha256=$_.driver_inf_sha256
          matching_device_id=$_.matching_device_id
          device_class_guid=$_.device_class_guid}})})
  if($driverFailures.Count){
    Stop-Gate 'FAIL_JTAG_WINUSB_DRIVER' `
        'One or more MI_02 devices do not match the pinned signed WinUSB binding'
  }

  Assert-InterfaceRegistration @($roles)
  Add-Step 'interface_registration' `
      $(if(@($roles|Where-Object{-not$_.interface_registration_proven}).Count){
        'FAIL'}else{'PASS'}) $false `
      ([pscustomobject]@{roles=@($roles|ForEach-Object{
        [pscustomobject]@{role=$_.role
          registry_guid_count=@($_.registry_interface_guids).Count
          pnputil_interface_count=@($_.pnputil_interfaces).Count
          proven=[bool]$_.interface_registration_proven}})})
  if(@($roles|Where-Object{-not$_.interface_registration_proven}).Count){
    Stop-Gate 'FAIL_JTAG_WINUSB_INTERFACE_UNREGISTERED' `
        'Expected DeviceInterfaceGUID is not both registered and enabled'
  }
  $terminalStatus='PASS_WINUSB_DRIVER_BINDING_PNP_ONLY'
} catch {
  $failure=$_.Exception.Message
}

$driverBindingPassed=$terminalStatus-ceq'PASS_WINUSB_DRIVER_BINDING_PNP_ONLY'
$summary=[pscustomobject][ordered]@{
  schema=$schema;test_id=$testId;started_utc=$startedUtc
  finished_utc=[DateTime]::UtcNow.ToString('o')
  result=if($driverBindingPassed){'PASS'}else{'FAIL'};status=$terminalStatus
  mode=if($OfflineContractTest){'OFFLINE_CONTRACT'}else{'LIVE_PNP_ONLY'}
  hardware_interaction=[bool]$hardwareInteraction
  fail_closed=$true;failure=$failure
  safety=[pscustomobject][ordered]@{
    com_opened=$false;flash_written=$false;target_config_loaded=$false
    target_halt_or_reset_issued=$false;target_state_modified=$false
    device_opened=$false;jtag_clocks_issued=$false;tap_reset_issued=$false
    openocd_invoked=$false;reader_preflight_invoked=$false
    active_jtag_proven=$false;firmware_install_allowed=$false}
  fixed_binding_policy=[pscustomobject][ordered]@{
    parent_key='DEVPKEY_Device_Parent'
    source_interface='VID_303A&PID_1001&MI_00'
    selected_interface='VID_303A&PID_1001&MI_02'
    driver_requirements=('Status=OK, Service=WINUSB, ProblemCode=0, ' +
      'pinned provider/version/INF hash/matching ID/class GUID')
    interface_registration=('Expected DeviceInterfaceGUID registry value AND ' +
      'enabled pnputil /enum-interfaces record')
    active_jtag='not attempted; separate authorization required'}
  toolchain=$toolchainEvidence;roles=@($roles)
  openocd_list=$null;steps=@($steps)
}
Write-Summary $summary
Write-Output ($summary|ConvertTo-Json -Depth 32 -Compress)
# Exit is intentionally nonzero even when the Windows driver binding is
# proven.  PnP-only evidence cannot authorize firmware installation.
exit 1
