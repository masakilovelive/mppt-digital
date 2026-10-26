[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$EvidenceDirectory = '',
  [switch]$Execute,

  # TestMode is intentionally restricted to an isolated temporary repository.
  # It replaces only the hardware inventory and esptool executable so the
  # command/evidence state machine can be tested without reaching a real COM
  # port. It is rejected for the production repository.
  [switch]$TestMode,
  [string]$TestEspToolPath = '',
  [string]$TestIdentityFixturePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$startedUtc = [DateTime]::UtcNow.ToString('o')
$script:StepRecords = [Collections.ArrayList]::new()
$script:ManifestVerifierInvocationCount = 0
$script:DeviceAccessAttempted = $false
$script:ProcessInventoryQueried = $false
$script:EspToolExecuted = $false
$script:FirmwareWriteAttempted = $false
$script:FirmwareMayHaveChanged = $false
$script:SuccessfulWrites = 0
$script:StageLocks = [Collections.ArrayList]::new()
$script:ExpectedEspToolVersion = '5.3.1'
$script:ExpectedProductionEspToolSha256 =
    'A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946'
$script:ExpectedTestEspToolSha256 =
    '7EF10A4AEC770E66CFCFCAF7EB2CC75DED3260A7AF640FB719E6E2AB16F181A0'

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256 `
      -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-BytesSha([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Write-Durable([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($parent)) `
      "Durable evidence has no parent: $Path"
  Assert-Condition (Test-Path -LiteralPath $parent -PathType Container) `
      "Durable evidence parent is missing: $parent"
  $bytes = $utf8.GetBytes($Text)
  $stream = [IO.FileStream]::new(
      $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-DurableBytes([string]$Path, [byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  Assert-Condition (Test-Path -LiteralPath $parent -PathType Container) `
      "Durable evidence parent is missing: $parent"
  $stream = [IO.FileStream]::new(
      $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
      [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($Bytes, 0, $Bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-DurableJson([string]$Path, [object]$Value) {
  Write-Durable $Path (($Value | ConvertTo-Json -Depth 32) + $newline)
  [void](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Flush-Existing([string]$Path) {
  $stream = [IO.FileStream]::new(
      $Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
  try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-RelativeEvidencePath([string]$Path, [string]$Root) {
  $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  $prefix = $Root.TrimEnd('\') + '\'
  Assert-Condition ($full.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) `
      "Evidence path escaped run root: $full"
  $full.Substring($prefix.Length).Replace('\', '/')
}

function Assert-ExactStringArray([object[]]$Actual, [string[]]$Expected,
                                 [string]$Description) {
  $actualArray = @($Actual)
  Assert-Condition ($actualArray.Count -eq $Expected.Count) `
      "$Description count mismatch"
  for ($index = 0; $index -lt $Expected.Count; ++$index) {
    Assert-Condition ([string]$actualArray[$index] -ceq $Expected[$index]) `
        "$Description mismatch at position $index"
  }
}

function Resolve-RepositoryFile([string]$RelativePath,
                                [string]$Description) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($RelativePath) -and
      -not [IO.Path]::IsPathRooted($RelativePath)) `
      "$Description path must be repository-relative"
  $candidate = [IO.Path]::GetFullPath(
      (Join-Path $repo ($RelativePath.Replace('/', '\'))))
  $prefix = $repo.TrimEnd('\') + '\'
  Assert-Condition ($candidate.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) `
      "$Description path escaped repository"
  Get-Item -LiteralPath $candidate -ErrorAction Stop
}

function Initialize-EvidenceDirectory([string]$Requested) {
  $allowedBaseText = Join-Path $repo `
      'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001'
  if (-not (Test-Path -LiteralPath $allowedBaseText -PathType Container)) {
    New-Item -ItemType Directory -Path $allowedBaseText -Force | Out-Null
  }
  $allowedBase = (Resolve-Path -LiteralPath $allowedBaseText).Path.TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($Requested)) {
    $leaf = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $Requested = Join-Path $allowedBase $leaf
  }
  $candidate = [IO.Path]::GetFullPath($Requested).TrimEnd('\')
  $parent = Split-Path -Parent $candidate
  Assert-Condition ($parent -ieq $allowedBase) `
      "EvidenceDirectory must be a direct child of $allowedBase"
  Assert-Condition (-not (Test-Path -LiteralPath $candidate)) `
      "Refusing to overwrite: evidence directory already exists: $candidate"
  New-Item -ItemType Directory -Path $candidate | Out-Null
  (Resolve-Path -LiteralPath $candidate).Path.TrimEnd('\')
}

function Get-RoleDefinitions {
  @(
    [pscustomobject][ordered]@{
      key='vehicle';name='Vehicle';port='COM3'
      pnp='USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
      parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
      mac='90:70:69:11:81:a4'
      expected_path='runs/phase6_arduino_compile/vehicle/vc_lora_vehicle_xiao_esp32s3.ino.bin'
      binary_path=$null;size_bytes=[int64]0;sha256=''
      stage_path=$null;stage_sha256=''
    },
    [pscustomobject][ordered]@{
      key='ground';name='Ground';port='COM6'
      pnp='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
      parent='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
      mac='1c:db:d4:5a:83:80'
      expected_path='runs/phase6_arduino_compile/ground/vc_lora_ground_xiao_esp32s3.ino.bin'
      binary_path=$null;size_bytes=[int64]0;sha256=''
      stage_path=$null;stage_sha256=''
    })
}

function Assert-ManifestAndSelectRoles([object]$Manifest) {
  Assert-Condition ([string]$Manifest.schema -ceq
      'vc-lora-phase6-firmware-manifest-v2') `
      'Unsupported Phase 6 firmware manifest schema'
  Assert-Condition ([string]$Manifest.fqbn -ceq
      'esp32:esp32:XIAO_ESP32S3') 'Unexpected firmware FQBN'
  Assert-Condition ([string]$Manifest.esp32_core -ceq '3.3.11') `
      'Unexpected ESP32 core version'
  Assert-ExactStringArray @($Manifest.compile_order) @('vehicle','ground') `
      'compile role order'

  $policy = $Manifest.flash_policy
  Assert-Condition ($null -ne $policy -and
      [string]$policy.mode -ceq 'app-only' -and
      $policy.app_only -is [bool] -and [bool]$policy.app_only -and
      [string]$policy.offset -ceq '0x10000' -and
      $policy.erase_flash -is [bool] -and -not [bool]$policy.erase_flash -and
      $policy.write_bootloader -is [bool] -and
        -not [bool]$policy.write_bootloader -and
      $policy.write_partition_table -is [bool] -and
        -not [bool]$policy.write_partition_table -and
      $policy.write_merged_image -is [bool] -and
        -not [bool]$policy.write_merged_image) `
      'Manifest is not exact app-only 0x10000 non-erasing policy'
  Assert-ExactStringArray @($policy.upload_order) @('vehicle','ground') `
      'flash upload role order'
  Assert-ExactStringArray @($policy.forbidden_selection_patterns) @(
      '*_flashed.bin','*bootloader*.bin','*partition*.bin','*merged*.bin',
      '*boot_app0*.bin') 'forbidden artifact policy'

  $records = @($Manifest.binaries)
  Assert-Condition ($records.Count -eq 2) `
      'Manifest must select exactly two application binaries'
  $roles = @(Get-RoleDefinitions)
  for ($index = 0; $index -lt $roles.Count; ++$index) {
    $record = $records[$index]
    $role = $roles[$index]
    Assert-Condition ([string]$record.role -ceq $role.key) `
        "Manifest binary role/order mismatch at position $index"
    Assert-Condition ([string]$record.path -ceq $role.expected_path) `
        "Manifest binary path mismatch for $($role.name)"
    Assert-Condition ([string]$record.path -cnotmatch
        '(?i)(?:_flashed|bootloader|partitions?|merged|boot_app0).*\.bin$') `
        "Forbidden firmware binary selected for $($role.name)"
    Assert-Condition ([string]$record.sha256 -cmatch '^[0-9A-F]{64}$') `
        "Manifest $($role.name) SHA-256 is non-canonical"
    [int64]$recordedSize = 0
    Assert-Condition ([int64]::TryParse([string]$record.size_bytes,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$recordedSize) -and $recordedSize -gt 0) `
        "Manifest $($role.name) size is invalid"
    $file = Resolve-RepositoryFile ([string]$record.path) `
        "$($role.name) binary"
    Assert-Condition ($file.Length -eq $recordedSize) `
        "$($role.name) binary size mismatch"
    $actualSha = Get-Sha $file.FullName
    Assert-Condition ($actualSha -ceq [string]$record.sha256) `
        "$($role.name) binary SHA-256 mismatch"
    $role.binary_path = $file.FullName
    $role.size_bytes = $recordedSize
    $role.sha256 = $actualSha
  }
  Assert-Condition ($roles[0].binary_path -ine $roles[1].binary_path) `
      'Vehicle and Ground binary paths are duplicated'
  $roles
}

function Invoke-ManifestVerifier([string]$Checkpoint) {
  $number = $script:ManifestVerifierInvocationCount
  $script:ManifestVerifierInvocationCount++
  $safeCheckpoint = ($Checkpoint -replace '[^A-Za-z0-9_-]', '_')
  $logPath = Join-Path $evidence `
      ('manifest_verify_{0:D2}_{1}.log' -f $number,$safeCheckpoint)
  $output = @()
  $failure = $null
  try {
    $output = @(& $manifestVerifier -RepoRoot $repo `
        -ManifestPath $manifestPath 2>&1)
  } catch {
    $failure = $_.Exception.Message
    $output += "ERROR: $failure"
  }
  Write-Durable $logPath (($output | Out-String).TrimEnd() + $newline)
  if ($null -ne $failure) {
    throw "Manifest verifier failed at ${Checkpoint}: $failure"
  }
  Assert-Condition ((($output | Out-String) -match
      'FW-PHASE6-MANIFEST-VERIFY-001\s+PASS')) `
      "Manifest verifier emitted no PASS marker at $Checkpoint"
}

function Assert-PinnedManifestAndBinaries([string]$Checkpoint,
                                           [bool]$RunVerifier = $true) {
  Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
      "Firmware manifest disappeared at $Checkpoint"
  Assert-Condition ((Get-Sha $manifestPath) -ceq $manifestSha256) `
      "Firmware manifest hash changed at $Checkpoint"
  foreach ($role in $roles) {
    Assert-Condition (Test-Path -LiteralPath $role.binary_path -PathType Leaf) `
        "$($role.name) binary disappeared at $Checkpoint"
    Assert-Condition ((Get-Item -LiteralPath $role.binary_path).Length -eq
        $role.size_bytes -and
        (Get-Sha $role.binary_path) -ceq $role.sha256) `
        "$($role.name) binary SHA-256 changed at $Checkpoint"
    if (-not [string]::IsNullOrWhiteSpace([string]$role.stage_path)) {
      Assert-Condition (Test-Path -LiteralPath $role.stage_path -PathType Leaf) `
          "$($role.name) staged binary disappeared at $Checkpoint"
      Assert-Condition ((Get-Item -LiteralPath $role.stage_path).Length -eq
          $role.size_bytes -and
          (Get-Sha $role.stage_path) -ceq $role.stage_sha256 -and
          $role.stage_sha256 -ceq $role.sha256) `
          "$($role.name) staged binary hash changed at $Checkpoint"
    }
  }
  if ($RunVerifier) { Invoke-ManifestVerifier $Checkpoint }
}

function Copy-RoleToLockedStage([object]$Role) {
  $stageDirectory = Join-Path $evidence 'staged'
  if (-not (Test-Path -LiteralPath $stageDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $stageDirectory | Out-Null
  }
  $destination = Join-Path $stageDirectory `
      ("$($Role.key).application.bin")
  $source = [IO.FileStream]::new(
      $Role.binary_path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
  try {
    $target = [IO.FileStream]::new(
        $destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
    try {
      $source.CopyTo($target, 65536)
      $target.Flush($true)
    } finally {
      $target.Dispose()
    }
  } finally {
    $source.Dispose()
  }
  $stageSha = Get-Sha $destination
  Assert-Condition ((Get-Item -LiteralPath $destination).Length -eq
      $Role.size_bytes -and $stageSha -ceq $Role.sha256) `
      "$($Role.name) staged application is not byte-exact"
  $Role.stage_path = (Resolve-Path -LiteralPath $destination).Path
  $Role.stage_sha256 = $stageSha
  $lock = [IO.FileStream]::new(
      $Role.stage_path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
  [void]$script:StageLocks.Add($lock)
}

function Copy-EspToolToLockedStage {
  $stageDirectory = Join-Path $evidence 'staged'
  if (-not (Test-Path -LiteralPath $stageDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $stageDirectory | Out-Null
  }
  $leaf = if ($TestMode.IsPresent) {
    'esptool-5.3.1.contract.ps1'
  } else {'esptool-5.3.1.exe'}
  $destination = Join-Path $stageDirectory $leaf
  $source = [IO.FileStream]::new(
      [string]$espTool.path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 65536, [IO.FileOptions]::SequentialScan)
  try {
    $target = [IO.FileStream]::new(
        $destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
    try {
      $source.CopyTo($target, 65536)
      $target.Flush($true)
    } finally {
      $target.Dispose()
    }
  } finally {
    $source.Dispose()
  }
  $stagedSha = Get-Sha $destination
  Assert-Condition ($stagedSha -ceq [string]$espTool.sha256) `
      'Staged esptool is not byte-exact'
  $espTool.execution_path = (Resolve-Path -LiteralPath $destination).Path
  $espTool.execution_sha256 = $stagedSha
  $lock = [IO.FileStream]::new(
      $espTool.execution_path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
  [void]$script:StageLocks.Add($lock)
}

function Assert-PinnedEspTool([string]$Checkpoint) {
  Assert-Condition (Test-Path -LiteralPath $espTool.path -PathType Leaf) `
      "Pinned esptool source disappeared at $Checkpoint"
  Assert-Condition ((Get-Sha $espTool.path) -ceq [string]$espTool.sha256) `
      "Pinned esptool source hash changed at $Checkpoint"
  if (-not [string]::IsNullOrWhiteSpace(
      [string]$espTool.execution_path)) {
    Assert-Condition (Test-Path -LiteralPath $espTool.execution_path `
        -PathType Leaf) "Staged esptool disappeared at $Checkpoint"
    Assert-Condition ((Get-Sha $espTool.execution_path) -ceq
        [string]$espTool.execution_sha256 -and
        [string]$espTool.execution_sha256 -ceq [string]$espTool.sha256) `
        "Staged esptool hash changed at $Checkpoint"
  }
}

function Resolve-EspTool {
  if ($TestMode.IsPresent) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($TestEspToolPath)) `
        'TestMode requires TestEspToolPath'
    $candidate = (Resolve-Path -LiteralPath $TestEspToolPath `
        -ErrorAction Stop).Path
    $prefix = $repo.TrimEnd('\') + '\'
    Assert-Condition ($candidate.StartsWith(
        $prefix, [StringComparison]::OrdinalIgnoreCase)) `
        'Test esptool escaped the isolated fixture repository'
    $expected = Join-Path $repo 'tools\fake_esptool.ps1'
    Assert-Condition ($candidate -ceq $expected) `
        'TestMode accepts only its exact fake esptool fixture path'
    $sha = Get-Sha $candidate
    Assert-Condition ($sha -ceq $script:ExpectedTestEspToolSha256) `
        'Test fake esptool fixture hash is not pinned'
    return [pscustomobject][ordered]@{
      path=$candidate;sha256=$sha;execution_path='';execution_sha256=''
      expected_version=$script:ExpectedEspToolVersion
      production_hash_pin_enforced=$false
    }
  }
  Assert-Condition ([string]::IsNullOrWhiteSpace($TestEspToolPath) -and
      [string]::IsNullOrWhiteSpace($TestIdentityFixturePath)) `
      'Test-only dependency paths are forbidden outside TestMode'
  $candidate = Join-Path $env:LOCALAPPDATA `
      'Arduino15\packages\esp32\tools\esptool_py\5.3.1\esptool.exe'
  $file = Get-Item -LiteralPath $candidate -ErrorAction Stop
  $sha = Get-Sha $file.FullName
  Assert-Condition ($sha -ceq $script:ExpectedProductionEspToolSha256) `
      "Pinned esptool SHA-256 mismatch: $sha"
  [pscustomobject][ordered]@{
    path=$file.FullName;sha256=$sha;execution_path='';execution_sha256=''
    expected_version=$script:ExpectedEspToolVersion
    production_hash_pin_enforced=$true
  }
}

function Get-PortIdentity([object]$Role) {
  $script:DeviceAccessAttempted = $true
  if ($TestMode.IsPresent) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace(
        $TestIdentityFixturePath)) `
        'Execute TestMode requires TestIdentityFixturePath'
    $fixturePath = (Resolve-Path -LiteralPath $TestIdentityFixturePath `
        -ErrorAction Stop).Path
    $prefix = $repo.TrimEnd('\') + '\'
    Assert-Condition ($fixturePath.StartsWith(
        $prefix, [StringComparison]::OrdinalIgnoreCase)) `
        'Test identity fixture escaped the isolated repository'
    Assert-Condition ($fixturePath -ceq
        (Join-Path $repo 'identity_fixture.json')) `
        'TestMode accepts only its exact identity fixture path'
    $fixtures = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
    $property = $fixtures.PSObject.Properties[[string]$Role.key]
    Assert-Condition ($null -ne $property) `
        "Test identity fixture lacks $($Role.key)"
    $record = $property.Value
    return [pscustomobject][ordered]@{
      captured_utc=[DateTime]::UtcNow.ToString('o')
      port=[string]$record.port;name=[string]$record.name
      description=[string]$record.description
      pnp_device_id=[string]$record.pnp_device_id
      parent_device_id=[string]$record.parent_device_id
      status=[string]$record.status
      availability=[int]$record.availability
      config_manager_error_code=[int]$record.config_manager_error_code
      location_paths=@($record.location_paths)
      source='test_fixture'
    }
  }

  $matches = @(Get-CimInstance Win32_SerialPort | Where-Object {
      [string]$_.DeviceID -ieq [string]$Role.port
    })
  Assert-Condition ($matches.Count -eq 1) `
      "$($Role.port) must resolve to exactly one Win32_SerialPort row"
  $row = $matches[0]
  $properties = @(Get-PnpDeviceProperty `
      -InstanceId ([string]$row.PNPDeviceID) -ErrorAction Stop)
  $parentRows = @($properties | Where-Object {
      $_.KeyName -ceq 'DEVPKEY_Device_Parent' })
  $locationRows = @($properties | Where-Object {
      $_.KeyName -ceq 'DEVPKEY_Device_LocationPaths' })
  Assert-Condition ($parentRows.Count -eq 1) `
      "$($Role.name) parent identity is unavailable"
  [pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    port=[string]$row.DeviceID;name=[string]$row.Name
    description=[string]$row.Description
    pnp_device_id=[string]$row.PNPDeviceID
    parent_device_id=[string]$parentRows[0].Data
    status=[string]$row.Status;availability=[int]$row.Availability
    config_manager_error_code=[int]$row.ConfigManagerErrorCode
    location_paths=if ($locationRows.Count -eq 1) {
      @($locationRows[0].Data)
    } else {@()}
    source='live_windows_inventory'
  }
}

function Assert-RoleIdentity([object]$Identity, [object]$Role) {
  Assert-Condition ([string]$Identity.port -ieq [string]$Role.port) `
      "$($Role.name) COM identity mismatch"
  Assert-Condition ([string]$Identity.pnp_device_id -ieq [string]$Role.pnp) `
      "$($Role.name) PNP identity mismatch: $($Identity.pnp_device_id)"
  Assert-Condition ([string]$Identity.parent_device_id -ieq
      [string]$Role.parent) `
      "$($Role.name) parent/MAC identity mismatch"
  Assert-Condition ([string]$Identity.status -ceq 'OK' -and
      [int]$Identity.config_manager_error_code -eq 0) `
      "$($Role.name) device status is not healthy"
}

function Wait-RoleIdentity([object]$Role, [int]$TimeoutSeconds = 20) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $lastFailure = ''
  do {
    try {
      $identity = Get-PortIdentity $Role
      Assert-RoleIdentity $identity $Role
      return $identity
    } catch {
      $lastFailure = $_.Exception.Message
      if ($TestMode.IsPresent) { throw }
      Start-Sleep -Milliseconds 500
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "$($Role.name) identity did not recover: $lastFailure"
}

function Get-CompetingClients {
  if ($TestMode.IsPresent) {
    return [pscustomobject][ordered]@{
      captured_utc=[DateTime]::UtcNow.ToString('o')
      known_serial_clients=@();explicit_com3_or_com6_refs=@()
      source='test_fixture_empty'
    }
  }
  $script:ProcessInventoryQueried = $true
  $knownNames = @(
    'missionplanner.exe','arduino-cli.exe','arduino-ide.exe',
    'python.exe','pythonw.exe','py.exe','putty.exe','ttermpro.exe',
    'coolterm.exe','mavproxy.exe',
    'qgroundcontrol.exe','esptool.exe','platformio.exe',
    'serialstudio.exe','plink.exe')
  $all = @(Get-CimInstance Win32_Process)
  [pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    known_serial_clients=@($all | Where-Object {
      $_.ProcessId -ne $PID -and
      $knownNames -contains ([string]$_.Name).ToLowerInvariant()
    } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
    explicit_com3_or_com6_refs=@($all | Where-Object {
      $_.ProcessId -ne $PID -and
      -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
      [string]$_.CommandLine -match
          '(?i)(^|[^A-Z0-9_])COM(3|6)([^0-9]|$)'
    } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
    source='live_windows_process_inventory'
  }
}

function Assert-NoCompetingClients {
  $snapshot = Get-CompetingClients
  Assert-Condition (@($snapshot.known_serial_clients).Count -eq 0) `
      'Known competing serial client is running'
  Assert-Condition (@($snapshot.explicit_com3_or_com6_refs).Count -eq 0) `
      'Another process command line references COM3 or COM6'
  $snapshot
}

function New-BaseArgv([object]$Role) {
  [string[]]@('--chip','esp32s3','--port',[string]$Role.port,
    '--baud','921600','--before','default-reset','--after','hard-reset')
}

function New-RoleArgv([object]$Role) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace(
      [string]$Role.stage_path)) "$($Role.name) has no staged application"
  [string[]]$base = @(New-BaseArgv $Role)
  [pscustomobject][ordered]@{
    read_mac=[string[]]($base + @('read-mac'))
    write=[string[]]($base + @('write-flash','-z','--flash-mode','keep',
      '--flash-freq','keep','--flash-size','keep','0x10000',
      [string]$Role.stage_path))
    verify=[string[]]($base + @('verify-flash','0x10000',
      [string]$Role.stage_path))
  }
}

function Assert-SafeArgv([ValidateSet('read_mac','write','verify')]
                         [string]$Kind, [string[]]$Tokens,
                         [object]$Role) {
  Assert-Condition ($Tokens.Count -ge 11 -and
      $Tokens[0] -ceq '--chip' -and $Tokens[1] -ceq 'esp32s3' -and
      $Tokens[2] -ceq '--port' -and $Tokens[3] -ceq [string]$Role.port -and
      $Tokens[4] -ceq '--baud' -and $Tokens[5] -ceq '921600' -and
      $Tokens[6] -ceq '--before' -and
      $Tokens[7] -ceq 'default-reset' -and
      $Tokens[8] -ceq '--after' -and $Tokens[9] -ceq 'hard-reset') `
      "$Kind base argv is not exact"
  foreach ($token in $Tokens) {
    Assert-Condition ($token -cnotmatch
        '(?i)(?:_flashed|bootloader|partitions?|merged|boot_app0).*\.bin$') `
        "$Kind selected a forbidden artifact"
    Assert-Condition ($token.ToLowerInvariant() -notin @(
        'erase-flash','erase-all','0x0','0x0000','0x8000','0xe000')) `
        "$Kind contains a forbidden flash token: $token"
  }
  if ($Kind -ceq 'read_mac') {
    Assert-Condition ($Tokens.Count -eq 11 -and
        $Tokens[10] -ceq 'read-mac') 'read-mac argv is not exact'
    return
  }
  Assert-Condition (@($Tokens | Where-Object {$_ -ceq '0x10000'}).Count `
      -eq 1) "$Kind must contain exactly one 0x10000"
  Assert-Condition (@($Tokens | Where-Object {
      $_ -ceq [string]$Role.stage_path}).Count -eq 1) `
      "$Kind must select the exact staged application"
  Assert-Condition (@($Tokens | Where-Object {
      $_.EndsWith('.bin',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1) `
      "$Kind must contain exactly one application binary"
  if ($Kind -ceq 'write') {
    Assert-Condition ($Tokens.Count -eq 20 -and
        @($Tokens | Where-Object {$_ -ceq 'write-flash'}).Count -eq 1) `
        'write-flash argv is not exact'
    Assert-ExactStringArray @($Tokens[11..18]) @(
      '-z','--flash-mode','keep','--flash-freq','keep','--flash-size','keep',
      '0x10000') 'write-flash policy argv'
  } else {
    Assert-Condition ($Tokens.Count -eq 13 -and
        $Tokens[10] -ceq 'verify-flash' -and
        $Tokens[11] -ceq '0x10000') 'verify-flash argv is not exact'
  }
}

function Invoke-CapturedEspTool([string]$Prefix, [string[]]$Tokens) {
  $stdoutPath = Join-Path $evidence "$Prefix.stdout.log"
  $stderrPath = Join-Path $evidence "$Prefix.stderr.log"
  $exitPath = Join-Path $evidence "$Prefix.exit.txt"
  $invokeFailure = $null
  $global:LASTEXITCODE = 0
  $script:EspToolExecuted = $true
  try {
    Assert-PinnedEspTool "before_$Prefix"
    $toolPath = [string]$espTool.execution_path
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($toolPath)) `
        "No immutable esptool execution copy for $Prefix"
    & $toolPath @Tokens 1> $stdoutPath 2> $stderrPath
  } catch {
    $invokeFailure = $_.Exception.Message
  }
  $exitCode = if ($null -ne $invokeFailure) { 255 } else {
    [int]$global:LASTEXITCODE
  }
  if (-not (Test-Path -LiteralPath $stdoutPath)) {
    Write-Durable $stdoutPath ''
  } else { Flush-Existing $stdoutPath }
  if (-not (Test-Path -LiteralPath $stderrPath)) {
    Write-Durable $stderrPath ''
  } else { Flush-Existing $stderrPath }
  Write-Durable $exitPath ([string]$exitCode + $newline)
  [pscustomobject][ordered]@{
    exit_code=$exitCode;invoke_failure=$invokeFailure
    stdout_path=$stdoutPath;stderr_path=$stderrPath;exit_path=$exitPath
    stdout_text=[IO.File]::ReadAllText($stdoutPath)
    stderr_text=[IO.File]::ReadAllText($stderrPath)
  }
}

function Invoke-EspToolVersion {
  $capture = Invoke-CapturedEspTool '00_esptool_version' @('version')
  $issues = [Collections.ArrayList]::new()
  if ($capture.exit_code -ne 0) {
    [void]$issues.Add("exit_code=$($capture.exit_code)")
  }
  if ((Get-Item -LiteralPath $capture.stderr_path).Length -ne 0) {
    [void]$issues.Add('stderr_not_empty')
  }
  if ($capture.stdout_text -notmatch '(?m)^\s*5\.3\.1\s*$') {
    [void]$issues.Add('version_5.3.1_marker_missing')
  }
  $record = [ordered]@{
    expected_version=$script:ExpectedEspToolVersion
    result=if ($issues.Count -eq 0) {'PASS'} else {'FAIL'}
    exit_code=$capture.exit_code;issues=@($issues)
    executable=$espTool
    stdout=[ordered]@{
      path=Get-RelativeEvidencePath $capture.stdout_path $evidence
      bytes=(Get-Item $capture.stdout_path).Length
      sha256=Get-Sha $capture.stdout_path
    }
    stderr=[ordered]@{
      path=Get-RelativeEvidencePath $capture.stderr_path $evidence
      bytes=(Get-Item $capture.stderr_path).Length
      sha256=Get-Sha $capture.stderr_path
    }
  }
  Write-DurableJson (Join-Path $evidence '00_esptool_version.record.json') `
      $record
  Assert-Condition ($issues.Count -eq 0) `
      "Pinned esptool version check failed: $(@($issues) -join '; ')"
}

function Invoke-FlashStep([int]$Number, [string]$Label,
                          [object]$Role,
                          [ValidateSet('read_mac','write','verify')]
                          [string]$Kind, [string[]]$Tokens) {
  Assert-PinnedManifestAndBinaries "before_$Label" $true
  [void](Assert-NoCompetingClients)
  $identityBefore = Wait-RoleIdentity $Role
  Assert-SafeArgv $Kind $Tokens $Role

  $prefix = '{0:D2}_{1}' -f $Number,$Label
  $argvPath = Join-Path $evidence "$prefix.argv.json"
  Write-DurableJson $argvPath ([object[]]$Tokens)
  $intentPath = $null
  if ($Kind -ceq 'write') {
    $intentPath = Join-Path $evidence "$prefix.intent.json"
    Write-DurableJson $intentPath ([ordered]@{
      schema_version=1;created_utc=[DateTime]::UtcNow.ToString('o')
      state='PRELAUNCH_FIRMWARE_MAY_CHANGE';terminal_record_required=$true
      role=[string]$Role.key;port=[string]$Role.port;offset='0x10000'
      identity=$identityBefore
      argv_path=Get-RelativeEvidencePath $argvPath $evidence
      argv_sha256=Get-Sha $argvPath
      manifest_sha256=$manifestSha256
      source_application_sha256=$Role.sha256
      staged_application_sha256=$Role.stage_sha256
      esptool_source_sha256=$espTool.sha256
      esptool_execution_sha256=$espTool.execution_sha256
    })
    $script:FirmwareWriteAttempted = $true
    $script:FirmwareMayHaveChanged = $true
  }
  $stepStarted = [DateTime]::UtcNow.ToString('o')
  $capture = Invoke-CapturedEspTool $prefix $Tokens
  $stepFinished = [DateTime]::UtcNow.ToString('o')
  $issues = [Collections.ArrayList]::new()
  if ($capture.exit_code -ne 0) {
    [void]$issues.Add("exit_code=$($capture.exit_code)")
  }
  if ((Get-Item -LiteralPath $capture.stderr_path).Length -ne 0) {
    [void]$issues.Add('stderr_not_empty')
  }
  $parsedMac = $null
  if ($Kind -ceq 'read_mac') {
    $matches = [regex]::Matches($capture.stdout_text,
        '(?im)^\s*MAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
    $macs = @($matches | ForEach-Object {
      $_.Groups[1].Value.ToLowerInvariant()
    } | Sort-Object -Unique)
    if ($macs.Count -ne 1) {
      [void]$issues.Add("unique_mac_count=$($macs.Count)")
    } else {
      $parsedMac = $macs[0]
      if ($parsedMac -cne [string]$Role.mac) {
        [void]$issues.Add("MAC_mismatch=$parsedMac")
      }
    }
  } elseif ($Kind -ceq 'write') {
    if (-not $capture.stdout_text.Contains('Hash of data verified.')) {
      [void]$issues.Add('write_hash_verification_marker_missing')
    }
  } elseif (-not $capture.stdout_text.Contains(
      'Verification successful (digest matched).')) {
    [void]$issues.Add('explicit_verify_marker_missing')
  }

  $identityAfter = $null
  try {
    $identityAfter = Wait-RoleIdentity $Role
  } catch {
    [void]$issues.Add("post_identity=$($_.Exception.Message)")
  }
  try {
    Assert-PinnedManifestAndBinaries "after_$Label" $true
  } catch {
    [void]$issues.Add("post_hash=$($_.Exception.Message)")
  }
  if ($Kind -ceq 'write' -and $issues.Count -eq 0) {
    $script:SuccessfulWrites++
  }

  $recordPath = Join-Path $evidence "$prefix.record.json"
  $record = [ordered]@{
    schema_version=1;number=$Number;label=$Label
    role=[string]$Role.key;kind=$Kind
    started_utc=$stepStarted;finished_utc=$stepFinished
    result=if ($issues.Count -eq 0) {'PASS'} else {'FAIL_STOP'}
    exit_code=$capture.exit_code;issues=@($issues)
    executable=[ordered]@{path=$espTool.path;sha256=$espTool.sha256}
    argv_path=Get-RelativeEvidencePath $argvPath $evidence
    argv_sha256=Get-Sha $argvPath
    stdout=[ordered]@{
      path=Get-RelativeEvidencePath $capture.stdout_path $evidence
      bytes=(Get-Item $capture.stdout_path).Length
      sha256=Get-Sha $capture.stdout_path
    }
    stderr=[ordered]@{
      path=Get-RelativeEvidencePath $capture.stderr_path $evidence
      bytes=(Get-Item $capture.stderr_path).Length
      sha256=Get-Sha $capture.stderr_path
    }
    exit_file=[ordered]@{
      path=Get-RelativeEvidencePath $capture.exit_path $evidence
      sha256=Get-Sha $capture.exit_path
    }
    identity_before=$identityBefore;identity_after=$identityAfter
    parsed_mac=$parsedMac
    manifest_sha256=$manifestSha256
    source_application=[ordered]@{
      path=$Role.binary_path;size_bytes=$Role.size_bytes;sha256=$Role.sha256
    }
    staged_application=[ordered]@{
      path=Get-RelativeEvidencePath $Role.stage_path $evidence
      size_bytes=(Get-Item $Role.stage_path).Length
      sha256=Get-Sha $Role.stage_path
      read_lock_held=$true
    }
  }
  Write-DurableJson $recordPath $record
  $record.record_path = Get-RelativeEvidencePath $recordPath $evidence
  $record.record_sha256 = Get-Sha $recordPath
  if ($Kind -ceq 'write') {
    Write-DurableJson (Join-Path $evidence "$prefix.terminal.json") `
        ([ordered]@{
          schema_version=1;finished_utc=[DateTime]::UtcNow.ToString('o')
          role=[string]$Role.key
          state=if ($issues.Count -eq 0) {
            'WRITE_HASH_VERIFIED'
          } else {'WRITE_OUTCOME_UNCERTAIN_FAIL_STOP'}
          result=$record.result;exit_code=$capture.exit_code
          intent_path=Get-RelativeEvidencePath $intentPath $evidence
          intent_sha256=Get-Sha $intentPath
          record_path=$record.record_path;record_sha256=$record.record_sha256
        })
  }
  [void]$script:StepRecords.Add([pscustomobject]$record)
  Assert-Condition ($issues.Count -eq 0) `
      "$Label failed: $(@($issues) -join '; ')"
}

function Complete-Evidence([string]$Result, [string]$Status,
                           [string]$FailureMessage) {
  $summaryPath = Join-Path $evidence 'summary.json'
  $roleSummary = [ordered]@{}
  foreach ($role in @($roles)) {
    $roleSummary[$role.key] = [ordered]@{
      port=$role.port;pnp_device_id=$role.pnp;parent_device_id=$role.parent
      mac=$role.mac;manifest_path=$role.expected_path
      source_path=$role.binary_path;size_bytes=$role.size_bytes
      sha256=$role.sha256
      staged_path=if ([string]::IsNullOrWhiteSpace(
          [string]$role.stage_path)) {$null} else {
        Get-RelativeEvidencePath $role.stage_path $evidence
      }
      write_pass=(@($script:StepRecords | Where-Object {
        $_.role -ceq $role.key -and $_.kind -ceq 'write' -and
        $_.result -ceq 'PASS'}).Count -eq 1)
      explicit_verify_pass=(@($script:StepRecords | Where-Object {
        $_.role -ceq $role.key -and $_.kind -ceq 'verify' -and
        $_.result -ceq 'PASS'}).Count -eq 1)
    }
  }
  $summary = [ordered]@{
    schema_version=1;test_id='FW-PHASE6-MANIFEST-FLASH-001'
    started_utc=$startedUtc;finished_utc=[DateTime]::UtcNow.ToString('o')
    mode=if ($Execute.IsPresent) {'Execute'} else {'DryRun'}
    result=$Result;status=$Status;failure=$FailureMessage
    evidence_root=$evidence
    runner=[ordered]@{path=$PSCommandPath;sha256=Get-Sha $PSCommandPath}
    manifest=[ordered]@{
      path=$manifestPath;sha256=$manifestSha256
      snapshot='input_firmware_manifest.json'
      verifier_path=$manifestVerifier
      verifier_invocation_count=$script:ManifestVerifierInvocationCount
    }
    flash_policy=[ordered]@{
      mode='app-only';offset='0x10000';erase_flash=$false
      write_bootloader=$false;write_partition_table=$false
      write_merged_image=$false;upload_order=@('vehicle','ground')
    }
    strict_sequence=@(
      'vehicle_read_mac','vehicle_write','vehicle_verify',
      'ground_read_mac','ground_write','ground_verify')
    completed_step_count=@($script:StepRecords | Where-Object {
      $_.result -ceq 'PASS'}).Count
    recorded_step_count=$script:StepRecords.Count
    steps=@($script:StepRecords | ForEach-Object {
      [ordered]@{
        number=$_.number;label=$_.label;role=$_.role;kind=$_.kind
        result=$_.result;exit_code=$_.exit_code
        record_path=$_.record_path;record_sha256=$_.record_sha256
        parsed_mac=$_.parsed_mac
      }
    })
    roles=$roleSummary
    esptool=$espTool
    external_actions=[ordered]@{
      device_access_attempted=$script:DeviceAccessAttempted
      process_inventory_queried=$script:ProcessInventoryQueried
      esptool_executed=$script:EspToolExecuted
      firmware_write_attempted=$script:FirmwareWriteAttempted
      firmware_may_have_changed=$script:FirmwareMayHaveChanged
      firmware_flash_performed=($script:SuccessfulWrites -gt 0)
      successful_application_writes=$script:SuccessfulWrites
      erase_performed=$false;bootloader_written=$false
      partition_table_written=$false;merged_image_written=$false
      device_power_changed=$false
    }
  }
  Write-DurableJson $summaryPath $summary

  $excluded = @(
    'artifact_manifest.json','SHA256SUMS.txt','final_seal.json',
    'final_seal.sha256')
  $rows = @(Get-ChildItem -LiteralPath $evidence -Recurse -File |
    Where-Object {$excluded -notcontains $_.Name} |
    Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path=Get-RelativeEvidencePath $_.FullName $evidence
        size_bytes=[int64]$_.Length;sha256=Get-Sha $_.FullName
      }
    })
  $artifactManifestPath = Join-Path $evidence 'artifact_manifest.json'
  Write-DurableJson $artifactManifestPath ([ordered]@{
    schema_version=1;result=$Result
    coverage='all evidence files present before artifact manifest/sums/seal'
    file_count=$rows.Count;files=$rows
  })
  $sumsPath = Join-Path $evidence 'SHA256SUMS.txt'
  Write-Durable $sumsPath ((@($rows | ForEach-Object {
    "$($_.sha256) *$($_.path)"
  }) -join $newline) + $newline)
  $sealPath = Join-Path $evidence 'final_seal.json'
  Write-DurableJson $sealPath ([ordered]@{
    schema_version=1;test_id='FW-PHASE6-MANIFEST-FLASH-001'
    finalized_utc=[DateTime]::UtcNow.ToString('o')
    mode=if ($Execute.IsPresent) {'Execute'} else {'DryRun'}
    result=$Result;summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha $artifactManifestPath
    sha256sums_sha256=Get-Sha $sumsPath
    manifest_sha256=$manifestSha256
    runner_sha256=Get-Sha $PSCommandPath
    vehicle_application_sha256=if ($roles.Count -eq 2) {$roles[0].sha256}else{''}
    ground_application_sha256=if ($roles.Count -eq 2) {$roles[1].sha256}else{''}
    external_action=if ($Execute.IsPresent) {
      'application-only flash attempt, strict Vehicle then Ground'
    } else {'none: offline manifest-bound dry-run'}
  })
  Write-Durable (Join-Path $evidence 'final_seal.sha256') `
      ((Get-Sha $sealPath) + ' *final_seal.json' + $newline)
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) `
      'Cannot resolve RepoRoot because PSScriptRoot is unavailable after binding'
  $RepoRoot = Split-Path -Parent $PSScriptRoot
  Assert-Condition (-not [string]::IsNullOrWhiteSpace($RepoRoot)) `
      'Cannot resolve RepoRoot from the bound PSScriptRoot'
}

$canonicalRepo = (Resolve-Path -LiteralPath `
    (Split-Path -Parent $PSScriptRoot) -ErrorAction Stop).Path.TrimEnd('\')
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path.TrimEnd('\')
if ($TestMode.IsPresent) {
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  Assert-Condition ($repo.StartsWith(
      $tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $repo) -match
        '^vc_lora_phase6_flash_contract_[0-9a-f]{32}$') `
      'TestMode is permitted only in an isolated Phase 6 flash fixture'
  $expectedFixtureWrapper = Join-Path $repo `
      'tools\invoke_phase6_manifest_flash.ps1'
  $runningWrapper = (Resolve-Path -LiteralPath $PSCommandPath `
      -ErrorAction Stop).Path
  Assert-Condition ($runningWrapper -ceq $expectedFixtureWrapper) `
      'TestMode requires executing the isolated fixture wrapper copy'
} else {
  Assert-Condition ($repo -ceq $canonicalRepo) `
      'Production flash wrapper must run against its canonical repository'
}

$evidence = Initialize-EvidenceDirectory $EvidenceDirectory
$manifestPath = Join-Path $repo `
    'runs\phase6_arduino_compile\firmware_manifest.json'
$manifestVerifier = Join-Path $repo `
    'tools\verify_phase6_firmware_manifest.ps1'
$manifestSha256 = ''
$roles = @()
$espTool = [pscustomobject][ordered]@{
  path='';sha256='';execution_path='';execution_sha256=''
  expected_version=$script:ExpectedEspToolVersion
  production_hash_pin_enforced=$false
}
$result = 'FAIL'
$status = 'FAIL_STOP_BEFORE_COMPLETION'
$failureMessage = ''

try {
  Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
      "Current Phase 6 firmware manifest is missing: $manifestPath"
  Assert-Condition (Test-Path -LiteralPath $manifestVerifier -PathType Leaf) `
      "Phase 6 manifest verifier is missing: $manifestVerifier"
  [byte[]]$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
  $manifestSha256 = Get-BytesSha $manifestBytes
  Write-DurableBytes (Join-Path $evidence 'input_firmware_manifest.json') `
      $manifestBytes
  $manifest = $utf8.GetString($manifestBytes) | ConvertFrom-Json
  $roles = @(Assert-ManifestAndSelectRoles $manifest)
  $espTool = Resolve-EspTool
  Assert-PinnedManifestAndBinaries 'initial_preflight' $true

  $prospectiveStagePaths = [ordered]@{
    vehicle='staged/vehicle.application.bin'
    ground='staged/ground.application.bin'
  }
  $preflight = [ordered]@{
    schema_version=1;checked_utc=[DateTime]::UtcNow.ToString('o')
    mode=if ($Execute.IsPresent) {'Execute'} else {'DryRun'}
    result='PASS';manifest_sha256=$manifestSha256
    manifest_verifier_pass=$true
    exact_roles=@('vehicle','ground')
    flash_policy=[ordered]@{
      application_only=$true;offset='0x10000';erase=$false
      bootloader=$false;partition_table=$false;merged=$false
      explicit_verify_required=$true
    }
    role_bindings=@($roles | ForEach-Object {
      [ordered]@{
        role=$_.key;port=$_.port;pnp_device_id=$_.pnp
        parent_device_id=$_.parent;mac=$_.mac
        manifest_path=$_.expected_path;size_bytes=$_.size_bytes
        sha256=$_.sha256;prospective_stage=$prospectiveStagePaths[$_.key]
      }
    })
    strict_sequence=@(
      'vehicle_read_mac','vehicle_write','vehicle_verify',
      'ground_read_mac','ground_write','ground_verify')
    esptool=[ordered]@{
      path=$espTool.path;sha256=$espTool.sha256
      expected_version=$espTool.expected_version
      production_hash_pin_enforced=$espTool.production_hash_pin_enforced
      version_executed=$false
    }
    external_actions=[ordered]@{
      device_access_attempted=$false;process_inventory_queried=$false
      esptool_executed=$false;firmware_write_attempted=$false
      device_power_changed=$false
    }
  }
  Write-DurableJson (Join-Path $evidence 'preflight.json') $preflight

  if (-not $Execute.IsPresent) {
    $result = 'PASS'
    $status = 'PASS_DRY_RUN_NO_DEVICE_OR_ESPTOOL_ACCESS'
  } else {
    foreach ($role in $roles) { Copy-RoleToLockedStage $role }
    Copy-EspToolToLockedStage
    Assert-PinnedManifestAndBinaries 'after_staging' $true
    Assert-PinnedEspTool 'after_staging'
    Invoke-EspToolVersion
    Assert-PinnedEspTool 'after_version_query'
    $clients = Assert-NoCompetingClients
    $initialVehicleIdentity = Wait-RoleIdentity $roles[0]
    $initialGroundIdentity = Wait-RoleIdentity $roles[1]
    Write-DurableJson (Join-Path $evidence 'live_preflight.json') `
        ([ordered]@{
          schema_version=1;result='PASS'
          checked_utc=[DateTime]::UtcNow.ToString('o')
          competing_clients=$clients
          vehicle_identity=$initialVehicleIdentity
          ground_identity=$initialGroundIdentity
          esptool_version='5.3.1';esptool_sha256=$espTool.sha256
        })

    $vehicleArgv = New-RoleArgv $roles[0]
    $groundArgv = New-RoleArgv $roles[1]
    Invoke-FlashStep 1 'vehicle_read_mac' $roles[0] 'read_mac' `
        $vehicleArgv.read_mac
    Invoke-FlashStep 2 'vehicle_write' $roles[0] 'write' `
        $vehicleArgv.write
    Invoke-FlashStep 3 'vehicle_verify' $roles[0] 'verify' `
        $vehicleArgv.verify
    Invoke-FlashStep 4 'ground_read_mac' $roles[1] 'read_mac' `
        $groundArgv.read_mac
    Invoke-FlashStep 5 'ground_write' $roles[1] 'write' `
        $groundArgv.write
    Invoke-FlashStep 6 'ground_verify' $roles[1] 'verify' `
        $groundArgv.verify
    Assert-PinnedManifestAndBinaries 'final_postflight' $true
    Assert-Condition ($script:SuccessfulWrites -eq 2 -and
        @($script:StepRecords | Where-Object {
          $_.result -ceq 'PASS'}).Count -eq 6) `
        'Strict six-step application flash did not complete'
    $result = 'PASS'
    $status = 'PASS_VEHICLE_THEN_GROUND_APP_ONLY_EXPLICIT_VERIFY'
  }
} catch {
  $failureMessage = $_.Exception.Message
  $status = 'FAIL_STOP_AFTER_' +
      (@($script:StepRecords | Where-Object {
        $_.result -ceq 'PASS'}).Count).ToString() + '_PASS_STEPS'
}

try {
  Complete-Evidence $result $status $failureMessage
} catch {
  $finalizationFailure = $_.Exception.Message
  if ([string]::IsNullOrWhiteSpace($failureMessage)) {
    throw "Phase 6 flash evidence finalization failed: $finalizationFailure"
  }
  throw ("Phase 6 flash failed: $failureMessage; evidence finalization " +
      "also failed: $finalizationFailure")
} finally {
  # Keep immutable staged applications locked through artifact hashing and the
  # final PASS/FAIL seal, not merely through the esptool process lifetime.
  foreach ($lock in @($script:StageLocks)) {
    try { $lock.Dispose() } catch {}
  }
  $script:StageLocks.Clear()
}

if ($result -cne 'PASS') {
  throw "PHASE6 MANIFEST FLASH STOP: $failureMessage"
}
$modeName = if ($Execute.IsPresent) {'Execute'} else {'DryRun'}
$sealSha256 = Get-Sha (Join-Path $evidence 'final_seal.json')
Write-Output (("FW-PHASE6-MANIFEST-FLASH-001 PASS mode={0} " +
    "evidence={1} seal_sha256={2}") -f $modeName,$evidence,$sealSha256)
