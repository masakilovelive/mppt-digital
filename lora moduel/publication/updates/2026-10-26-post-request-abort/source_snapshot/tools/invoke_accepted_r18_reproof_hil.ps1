[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$EvidenceDirectory = '',
  [switch]$Execute,
  [ValidateSet('', 'VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN')]
  [string]$HilAuthorization = '',
  [ValidateSet('', 'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED')]
  [string]$OperatorSafetyAttestation = '',

  # Pure, offline state-machine seam. It never inventories a process or device
  # and never starts esptool. It exists only for the contract test below.
  [switch]$OfflineContractTest,
  [ValidateSet('both_match','vehicle_mismatch','ground_mismatch',
    'both_mismatch','read_failure','identity_failure','restore_failure',
    'esptool_failure_reenumeration_success',
    'esptool_failure_reenumeration_failure',
    'marker_failure_reenumeration_success',
    'read_mac_mismatch_usb_role_proven',
    'write_then_finalization_failure',
    'write_then_emergency_terminal_write_failure',
    'fake_verify_match',
    'fake_read_midstream_failure',
    'fake_read_wrong_size_exit0',
    'fake_read_full_match',
    'fake_read_full_mismatch',
    'fake_direct_unproven_write',
    'fake_read_full_match_spaced_paths')]
  [string]$OfflineScenario = 'both_match',
  [string]$OfflineFakeEspToolScript = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine
$schema = 'vc-lora-accepted-r18-reproof-evidence-v1'
$testId = 'ACCEPTED-R18-REPROOF-HIL-001'
$authorizationText =
    'VERIFY_ACCEPTED_R18_AND_RESTORE_PROVEN_MISMATCH_ONE_RUN'
$safetyText =
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED'
$expectedEspToolVersion = '5.3.1'
$expectedEspToolSha256 =
    'A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946'
$appOffset = '0x10000'
$startedUtc = [DateTime]::UtcNow.ToString('o')

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).
      Hash.ToUpperInvariant()
}

function Get-TextSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    (($sha.ComputeHash($utf8.GetBytes($Text)) | ForEach-Object {
      $_.ToString('x2')
    }) -join '').ToUpperInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Write-DurableBytes([string]$Path, [byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and
      -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
  $temp = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllBytes($temp, $Bytes)
  $stream = [IO.File]::Open($temp, [IO.FileMode]::Open,
      [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { $stream.Flush($true) } finally { $stream.Dispose() }
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-DurableText([string]$Path, [string]$Text) {
  Write-DurableBytes $Path $utf8.GetBytes($Text)
}

function Write-DurableJson([string]$Path, [object]$Value) {
  Write-DurableText $Path (($Value | ConvertTo-Json -Depth 20) + $newline)
}

function Copy-PinnedToStage([string]$Source, [string]$Destination,
                            [string]$ExpectedSha256,
                            [int64]$ExpectedBytes) {
  $file = Get-Item -LiteralPath $Source -ErrorAction Stop
  Assert-Condition ([int64]$file.Length -eq $ExpectedBytes) `
      "Pinned source size mismatch: $Source"
  Assert-Condition ((Get-Sha256 $file.FullName) -ceq $ExpectedSha256) `
      "Pinned source SHA-256 mismatch: $Source"
  [byte[]]$bytes = [IO.File]::ReadAllBytes($file.FullName)
  Write-DurableBytes $Destination $bytes
  Assert-Condition ((Get-Sha256 $Destination) -ceq $ExpectedSha256) `
      "Staged file SHA-256 mismatch: $Destination"
}

function Open-PinnedReadLock([string]$Path, [string]$ExpectedSha256) {
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  Assert-Condition ((Get-Sha256 $resolved) -ceq $ExpectedSha256) `
      "Pinned staged file changed: $resolved"
  [IO.FileStream]::new($resolved, [IO.FileMode]::Open,
      [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function New-RoleRecord([object]$Pin) {
  [pscustomobject][ordered]@{
    key=[string]$Pin.key
    name=[string]$Pin.name
    port=[string]$Pin.port
    expected_parent=[string]$Pin.parent
    expected_mac=[string]$Pin.mac
    expected_application_sha256=[string]$Pin.sha256
    expected_application_bytes=[int64]$Pin.bytes
    identity_verified=$false
    read_mac_verified=$false
    pinned_verify_attempted=$false
    pinned_verify_matched=$false
    pinned_verify_failure_ambiguous=$false
    readback_succeeded=$false
    readback_sha256=$null
    mismatch_proven=$false
    restore_attempted=$false
    restore_succeeded=$false
    final_readback_succeeded=$false
    final_readback_sha256=$null
    accepted_r18_proven=$false
    device_operation_count=0
    device_targeting_operation_entered=$false
    device_targeting_operation_attempted=$false
    hard_reset_requested=$false
    exact_usb_role_present=$false
    reenumeration_attempted=$false
    reenumeration_proven=$false
    last_reenumeration_status=$null
    application_liveness_proven=$false
    issues=@()
  }
}

function Get-ProcessAncestorIds([object[]]$Processes,
                                [int]$StartProcessId) {
  $byId = @{}
  foreach ($process in @($Processes)) {
    if ($null -eq $process.PSObject.Properties['ProcessId']) { continue }
    $id = [int]$process.ProcessId
    if ($id -gt 0) { $byId[$id] = $process }
  }
  $result = [Collections.Generic.List[int]]::new()
  $seen = [Collections.Generic.HashSet[int]]::new()
  $cursor = $StartProcessId
  while ($cursor -gt 0 -and $seen.Add($cursor)) {
    $result.Add($cursor)
    if (-not $byId.ContainsKey($cursor) -or
        $null -eq $byId[$cursor].PSObject.Properties['ParentProcessId']) {
      break
    }
    $cursor = [int]$byId[$cursor].ParentProcessId
  }
  $result.ToArray()
}

function Get-CompetingClientGate {
  if ($script:OfflineFakeProcessMode) {
    return [pscustomobject][ordered]@{
      schema='vc-lora-r18-process-gate-v1'
      captured_utc=[DateTime]::UtcNow.ToString('o')
      result='PASS'
      fail_closed=$true
      offline_fake_process_test=$true
      blocked_processes=@()
    }
  }
  $script:ExternalActions.process_inventory_queried = $true
  $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $ancestors = @(Get-ProcessAncestorIds $all $PID)
  $ancestorSet = [Collections.Generic.HashSet[int]]::new()
  foreach ($id in $ancestors) { [void]$ancestorSet.Add([int]$id) }
  $known = @(
    'missionplanner.exe','arduino-cli.exe','arduino-ide.exe',
    'putty.exe','ttermpro.exe','coolterm.exe','mavproxy.exe',
    'qgroundcontrol.exe','esptool.exe','platformio.exe',
    'serialstudio.exe','plink.exe','screen.exe','minicom.exe')
  $blocked = @($all | Where-Object {
    [int]$_.ProcessId -ne $PID -and
    -not $ancestorSet.Contains([int]$_.ProcessId) -and
    (([string]$_.Name).ToLowerInvariant() -in $known -or
      (-not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
       [string]$_.CommandLine -match
          '(?i)(^|[^A-Z0-9_])COM(3|6)([^0-9]|$)'))
  } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
  [pscustomobject][ordered]@{
    schema='vc-lora-r18-process-gate-v1'
    captured_utc=[DateTime]::UtcNow.ToString('o')
    result=if ($blocked.Count -eq 0) {'PASS'}else{'FAIL'}
    fail_closed=$true
    blocked_processes=$blocked
  }
}

function Assert-ProcessGate([string]$Checkpoint) {
  $gate = Get-CompetingClientGate
  $script:ProcessGateSequence++
  $leaf = 'process_gate_{0:D2}_{1}.json' -f `
      $script:ProcessGateSequence,$Checkpoint
  Write-DurableJson (Join-Path $evidence $leaf) $gate
  Assert-Condition ([string]$gate.result -ceq 'PASS') `
      "Competing serial client detected at $Checkpoint"
  $gate
}

function Get-PortIdentity([object]$Role) {
  if ($script:OfflineFakeProcessMode) {
    return [pscustomobject][ordered]@{
      captured_utc=[DateTime]::UtcNow.ToString('o')
      port=[string]$Role.port
      pnp_device_id=[string]$Role.pnp
      parent_device_id=[string]$Role.parent
      status='OK'
      config_manager_error_code=0
      offline_fake_process_test=$true
    }
  }
  $script:ExternalActions.device_access_attempted = $true
  $rows = @(Get-CimInstance Win32_SerialPort -ErrorAction Stop |
      Where-Object { [string]$_.DeviceID -ieq [string]$Role.port })
  Assert-Condition ($rows.Count -eq 1) `
      "$($Role.port) must resolve to exactly one serial device"
  $row = $rows[0]
  $properties = @(Get-PnpDeviceProperty -InstanceId `
      ([string]$row.PNPDeviceID) -ErrorAction Stop)
  $parents = @($properties | Where-Object {
      $_.KeyName -ceq 'DEVPKEY_Device_Parent' })
  Assert-Condition ($parents.Count -eq 1) `
      "$($Role.name) parent identity is unavailable"
  [pscustomobject][ordered]@{
    captured_utc=[DateTime]::UtcNow.ToString('o')
    port=[string]$row.DeviceID
    pnp_device_id=[string]$row.PNPDeviceID
    parent_device_id=[string]$parents[0].Data
    status=[string]$row.Status
    config_manager_error_code=[int]$row.ConfigManagerErrorCode
  }
}

function Assert-RoleIdentity([object]$Identity, [object]$Role) {
  Assert-Condition ([string]$Identity.port -ieq [string]$Role.port) `
      "$($Role.name) port identity mismatch"
  Assert-Condition ([string]$Identity.pnp_device_id -ieq [string]$Role.pnp) `
      "$($Role.name) PNP identity mismatch"
  Assert-Condition ([string]$Identity.parent_device_id -ieq `
      [string]$Role.parent) "$($Role.name) parent identity mismatch"
  Assert-Condition ([string]$Identity.status -ceq 'OK' -and
      [int]$Identity.config_manager_error_code -eq 0) `
      "$($Role.name) device status is not healthy"
}

function Wait-RoleIdentity([object]$Role, [int]$TimeoutSeconds = 20) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $last = ''
  do {
    try {
      $identity = Get-PortIdentity $Role
      Assert-RoleIdentity $identity $Role
      return $identity
    } catch {
      $last = $_.Exception.Message
      Start-Sleep -Milliseconds 500
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "$($Role.name) identity/re-enumeration failed: $last"
}

function New-ExactArgv([object]$Role,
    [ValidateSet('version','read_mac','read_flash','write','verify')][string]$Kind,
    [string]$FilePath = '') {
  if ($Kind -ceq 'version') { return [string[]]@('version') }
  [string[]]$base = @('--chip','esp32s3','--port',[string]$Role.port,
    '--baud','921600','--before','default-reset','--after','hard-reset')
  if ($Kind -ceq 'read_mac') { return [string[]]($base + @('read-mac')) }
  if ($Kind -ceq 'read_flash') {
    [string[]]$readBase = @('--chip','esp32s3','--port',
      [string]$Role.port,'--baud','115200','--before','default-reset',
      '--after','hard-reset','--no-stub')
    return [string[]]($readBase + @('read-flash','--flash-size','8MB',
      '--no-progress',$appOffset,[string]$Role.bytes,$FilePath))
  }
  if ($Kind -ceq 'write') {
    return [string[]]($base + @('write-flash','-z','--flash-mode','keep',
      '--flash-freq','keep','--flash-size','keep',$appOffset,$FilePath))
  }
  [string[]]($base + @('verify-flash',$appOffset,$FilePath))
}

function Assert-SafeArgv([string[]]$Tokens, [object]$Role,
    [ValidateSet('version','read_mac','read_flash','write','verify')][string]$Kind,
    [string]$FilePath = '') {
  if ($Kind -ceq 'version') {
    Assert-Condition ($Tokens.Count -eq 1 -and $Tokens[0] -ceq 'version') `
        'version argv is not exact'
    return
  }
  $expectedBaud = if ($Kind -ceq 'read_flash') {'115200'}else{'921600'}
  Assert-Condition ($Tokens.Count -ge 11 -and
      $Tokens[0] -ceq '--chip' -and $Tokens[1] -ceq 'esp32s3' -and
      $Tokens[2] -ceq '--port' -and $Tokens[3] -ceq $Role.port -and
      $Tokens[4] -ceq '--baud' -and $Tokens[5] -ceq $expectedBaud -and
      $Tokens[6] -ceq '--before' -and
      $Tokens[7] -ceq 'default-reset' -and
      $Tokens[8] -ceq '--after' -and $Tokens[9] -ceq 'hard-reset') `
      "$Kind base argv is not exact"
  if ($Kind -ceq 'read_flash') {
    Assert-Condition ($Tokens.Count -eq 18 -and
        $Tokens[10] -ceq '--no-stub' -and
        $Tokens[11] -ceq 'read-flash' -and
        $Tokens[12] -ceq '--flash-size' -and
        $Tokens[13] -ceq '8MB' -and
        $Tokens[14] -ceq '--no-progress' -and
        $Tokens[15] -ceq $appOffset -and
        $Tokens[16] -ceq [string]$Role.bytes -and
        $Tokens[17] -ceq $FilePath) `
        'read_flash argv is not exact no-stub conservative readback'
  } else {
    Assert-Condition (@($Tokens | Where-Object {$_ -ceq '--no-stub'}).Count `
        -eq 0) "$Kind must preserve the existing stub transport"
  }
  foreach ($token in $Tokens) {
    Assert-Condition ($token -cnotmatch
      '(?i)(?:bootloader|partitions?|merged|boot_app0).*\.bin$') `
      "$Kind selected a forbidden image"
    Assert-Condition ($token.ToLowerInvariant() -notin @(
      'erase-all','erase-region','0x0','0x0000','0x8000','0xe000')) `
      "$Kind contains a forbidden address/action"
  }
  if ($Kind -ne 'read_mac') {
    Assert-Condition (@($Tokens | Where-Object {$_ -ceq $appOffset}).Count `
        -eq 1) "$Kind is not bound to exact app offset"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($FilePath) -and
        @($Tokens | Where-Object {$_ -ceq $FilePath}).Count -eq 1) `
        "$Kind file binding is not exact"
  }
}

function ConvertTo-ProcessArgument([string]$Value) {
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $builder = New-Object Text.StringBuilder
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      $slashes++
      continue
    }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($slashes * 2) + 1)))
      [void]$builder.Append('"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$builder.Append(('\' * $slashes))
      $slashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($slashes -gt 0) {
    [void]$builder.Append(('\' * ($slashes * 2)))
  }
  [void]$builder.Append('"')
  $builder.ToString()
}

function Get-OutputFileState([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject][ordered]@{
      path=$null;exists=$false;bytes=$null;sha256=$null
    }
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject][ordered]@{
      path=$Path;exists=$false;bytes=$null;sha256=$null
    }
  }
  [pscustomobject][ordered]@{
    path=$Path
    exists=$true
    bytes=[int64](Get-Item -LiteralPath $Path).Length
    sha256=Get-Sha256 $Path
  }
}

function Get-LastReadProgress([string]$Text) {
  $matches = [regex]::Matches($Text,
      '(?im)^(?<prefix>[^\r\n]*?)(?<percent>\d+(?:\.\d+)?)%\s+' +
      '(?<done>\d+)/(?<total>\d+)\s+bytes')
  if ($matches.Count -eq 0) { return $null }
  $match = $matches[$matches.Count - 1]
  $addressMatch = [regex]::Match($match.Groups['prefix'].Value,
      '(?i)Reading\s+from\s+(?<address>0x[0-9a-f]+)')
  [pscustomobject][ordered]@{
    percent=[double]$match.Groups['percent'].Value
    completed_bytes=[int64]$match.Groups['done'].Value
    total_bytes=[int64]$match.Groups['total'].Value
    address=if ($addressMatch.Success) {
      $addressMatch.Groups['address'].Value.ToLowerInvariant()
    } else {$null}
    text=$match.Value
  }
}

function Invoke-CapturedProcess([string]$Prefix, [string]$Executable,
    [string[]]$ProcessArgv, [string]$LogicalArgvPath,
    [string]$OutputFile = '', [string]$OperationKind = '',
    [string]$StubMode = '', [string]$Baud = '') {
  $stdoutPath = Join-Path $evidence "$Prefix.stdout.log"
  $stderrPath = Join-Path $evidence "$Prefix.stderr.log"
  $processArgvPath = Join-Path $evidence "$Prefix.process_argv.json"
  Write-DurableJson $processArgvPath @($ProcessArgv)
  $started = [DateTime]::UtcNow
  $finished = $null
  $processStarted = $false
  $processCompleted = $false
  $exitCode = $null
  $stdoutText = ''
  $stderrText = ''
  $exception = $null
  $process = New-Object Diagnostics.Process
  try {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = (@($ProcessArgv | ForEach-Object {
      ConvertTo-ProcessArgument ([string]$_)
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($null -ne $startInfo.PSObject.Properties['StandardOutputEncoding']) {
      $startInfo.StandardOutputEncoding = $utf8
      $startInfo.StandardErrorEncoding = $utf8
    }
    $process.StartInfo = $startInfo
    $processStarted = $process.Start()
    Assert-Condition $processStarted "could not start process for $Prefix"
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $exitCode = [int]$process.ExitCode
    $processCompleted = $true
  } catch {
    $errorRecord = $_
    $exception = [pscustomobject][ordered]@{
      occurred=$true
      type=if ($null -ne $errorRecord.Exception) {
        $errorRecord.Exception.GetType().FullName
      } else {$null}
      message=if ($null -ne $errorRecord.Exception) {
        $errorRecord.Exception.Message
      } else {[string]$errorRecord}
      hresult=if ($null -ne $errorRecord.Exception) {
        [int]$errorRecord.Exception.HResult
      } else {$null}
      fully_qualified_error_id=[string]$errorRecord.FullyQualifiedErrorId
    }
    if ($processStarted) {
      try {
        if (-not $process.HasExited) { $process.Kill() }
        $process.WaitForExit()
      } catch {}
      try { $exitCode = [int]$process.ExitCode } catch {}
    }
  } finally {
    $finished = [DateTime]::UtcNow
    $process.Dispose()
  }
  Write-DurableText $stdoutPath $stdoutText
  Write-DurableText $stderrPath $stderrText
  $exitText = if ($null -eq $exitCode) {'NOT_STARTED'}else{[string]$exitCode}
  Write-DurableText (Join-Path $evidence "$Prefix.exit.txt") `
      ($exitText + $newline)
  $stdoutFile = Get-Item -LiteralPath $stdoutPath
  $stderrFile = Get-Item -LiteralPath $stderrPath
  $result = [pscustomobject][ordered]@{
    schema='vc-lora-esptool-process-result-v1'
    operation_prefix=$Prefix
    operation_kind=$OperationKind
    stub_mode=$StubMode
    baud=$Baud
    started_utc=$started.ToString('o')
    finished_utc=$finished.ToString('o')
    duration_ms=[math]::Round(($finished - $started).TotalMilliseconds,3)
    executable=$Executable
    executable_sha256=if (Test-Path -LiteralPath $Executable -PathType Leaf) {
      Get-Sha256 $Executable
    } else {$null}
    argv_path=$LogicalArgvPath
    argv_sha256=Get-Sha256 $LogicalArgvPath
    process_argv_path=$processArgvPath
    process_argv_sha256=Get-Sha256 $processArgvPath
    process_started=$processStarted
    process_completed=$processCompleted
    exit_code=$exitCode
    exception=$exception
    stdout=[pscustomobject][ordered]@{
      path=$stdoutPath;bytes=[int64]$stdoutFile.Length
      sha256=Get-Sha256 $stdoutPath
    }
    stderr=[pscustomobject][ordered]@{
      path=$stderrPath;bytes=[int64]$stderrFile.Length
      sha256=Get-Sha256 $stderrPath
    }
    output_file=Get-OutputFileState $OutputFile
    last_progress=Get-LastReadProgress ($stdoutText + $newline + $stderrText)
  }
  Write-DurableJson (Join-Path $evidence "$Prefix.process_result.json") $result
  [pscustomobject][ordered]@{
    exit_code=$exitCode
    invoke_failure=$exception
    stdout_text=$stdoutText
    stderr_text=$stderrText
    process_result=$result
  }
}

function Invoke-EspTool([string]$Prefix, [object]$Role,
    [ValidateSet('version','read_mac','read_flash','write','verify')][string]$Kind,
    [string]$FilePath = '', [object]$DeviceRecord = $null) {
  [string[]]$argv = New-ExactArgv $Role $Kind $FilePath
  Assert-SafeArgv $argv $Role $Kind $FilePath
  $stubMode = if ($Kind -ceq 'read_flash') {'rom_no_stub'}else{'stub'}
  $baud = if ($Kind -ceq 'read_flash') {'115200'}else{'921600'}
  $argvPath = Join-Path $evidence "$Prefix.argv.json"
  Write-DurableJson $argvPath @($argv)
  if ($Kind -cne 'version') {
    Assert-Condition ($null -ne $DeviceRecord) `
        "$Kind requires a device-operation record"
  }
  if ($Kind -eq 'write') {
    # BEGIN_PROVEN_MISMATCH_WRITE_GATE
    Assert-Condition ([bool]$DeviceRecord.readback_succeeded -and
        [bool]$DeviceRecord.mismatch_proven -and
        -not [string]::IsNullOrWhiteSpace(
          [string]$DeviceRecord.readback_sha256) -and
        [string]$DeviceRecord.readback_sha256 -cne
          [string]$DeviceRecord.expected_application_sha256) `
        ('Write is forbidden without a successful full-length readback ' +
         'whose SHA-256 proves a mismatch')
    # END_PROVEN_MISMATCH_WRITE_GATE
    if ($script:OfflineFakeProcessMode) {
      $script:OfflineSimulatedWrite = $true
    } else {
      $script:ExternalActions.firmware_write_attempted = $true
      $script:ExternalActions.firmware_may_have_changed = $true
    }
    Write-DurableJson (Join-Path $evidence "$Prefix.write_intent.json") `
        ([ordered]@{
          schema='vc-lora-r18-app-only-write-intent-v1'
          created_utc=[DateTime]::UtcNow.ToString('o')
          role=$Role.key;port=$Role.port;offset=$appOffset
          app_only=$true;erase_allowed=$false
          application_sha256=$Role.sha256
          mismatch_proven_before_write=$true
        })
  }
  if ($script:OfflineFakeProcessMode) {
    $script:OfflineSimulatedDeviceExecution = $true
  } else {
    $script:ExternalActions.esptool_executed = $true
  }
  if (-not $script:OfflineFakeProcessMode) {
    Assert-Condition ((Get-Sha256 $script:EspToolPath) -ceq
        $expectedEspToolSha256) 'Staged esptool changed before execution'
  }
  if ($Kind -cne 'version') {
    $DeviceRecord.device_targeting_operation_attempted = $true
    $DeviceRecord.hard_reset_requested = $true
    $script:DeviceTargetingOperationAttempted = $true
    Write-DurableJson (Join-Path $evidence `
        "$Prefix.device_operation_attempt.json") ([ordered]@{
      schema='vc-lora-r18-device-operation-state-v1'
      created_utc=[DateTime]::UtcNow.ToString('o')
      operation_prefix=$Prefix;role=$Role.key;port=$Role.port
      kind=$Kind;entered=$true;attempted=$true
      hard_reset_requested=$true
      application_liveness_proven=$false
    })
  }
  if ($script:OfflineFakeProcessMode) {
    $hostExecutable = if ($PSVersionTable.PSEdition -ceq 'Desktop') {
      Join-Path $PSHOME 'powershell.exe'
    } else {
      Join-Path $PSHOME 'pwsh.exe'
    }
    [string[]]$processArgv = @(
      '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
      '-File',$script:OfflineFakeEspToolScriptPath,
      '-Scenario',$OfflineScenario,
      '-Kind',$Kind,
      '-Role',[string]$Role.key,
      '-OutputFile',$FilePath,
      '-AcceptedFile',[string]$Role.stage,
      '-StateFile',(Join-Path $evidence "fake_$($Role.key)_restored.state"))
    return Invoke-CapturedProcess $Prefix $hostExecutable $processArgv `
        $argvPath $(if ($Kind -ceq 'read_flash') {$FilePath}else{''}) `
        $Kind $stubMode $baud
  }
  Invoke-CapturedProcess $Prefix $script:EspToolPath $argv $argvPath `
      $(if ($Kind -ceq 'read_flash') {$FilePath}else{''}) `
      $Kind $stubMode $baud
}

function Invoke-DeviceEspTool([string]$Prefix, [object]$Role,
    [object]$Record,
    [ValidateSet('read_mac','read_flash','write','verify')][string]$Kind,
    [string]$FilePath = '') {
  $script:DeviceTargetingOperationEntered = $true
  $Record.device_targeting_operation_entered = $true
  $Record.device_operation_count = [int]$Record.device_operation_count + 1
  $Record.exact_usb_role_present = $false
  $Record.reenumeration_attempted = $true
  $Record.reenumeration_proven = $false
  $Record.last_reenumeration_status = 'PENDING'
  $Record.application_liveness_proven = $false
  Write-DurableJson (Join-Path $evidence `
      "$Prefix.device_operation_entered.json") ([ordered]@{
    schema='vc-lora-r18-device-operation-state-v1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    operation_prefix=$Prefix;role=$Role.key;port=$Role.port
    kind=$Kind;entered=$true;attempted=$false
    hard_reset_requested=$false
    application_liveness_proven=$false
  })
  $capture = $null
  $operationFailure = $null
  try {
    $capture = Invoke-EspTool $Prefix $Role $Kind $FilePath $Record
  } catch {
    $operationFailure = $_.Exception.Message
  }

  $reenumeration = [ordered]@{
    schema='vc-lora-r18-exact-usb-role-reenumeration-v1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    operation_prefix=$Prefix
    role=$Role.key
    port=$Role.port
    expected_pnp_device_id=$Role.pnp
    expected_parent_device_id=$Role.parent
    hard_reset_requested=[bool]$Record.hard_reset_requested
    attempted=$true
    proven=$false
    exact_usb_role_present=$false
    application_liveness_proven=$false
    identity=$null
    issue=$null
  }
  try {
    $identity = Wait-RoleIdentity $Role
    $reenumeration.identity = $identity
    $reenumeration.proven = $true
    $reenumeration.exact_usb_role_present = $true
    $Record.reenumeration_proven = $true
    $Record.exact_usb_role_present = $true
    $Record.last_reenumeration_status = if ($Record.hard_reset_requested) {
      'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST'
    } else {
      'PASS_EXACT_USB_ROLE_PRESENT_WITHOUT_DEVICE_OPERATION_ATTEMPT'
    }
  } catch {
    $reenumeration.issue = $_.Exception.Message
    $Record.last_reenumeration_status =
        'FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN'
    $Record.exact_usb_role_present = $false
    $script:ExactUsbRoleReenumerationUnproven = $true
  }

  $reenumerationPath = Join-Path $evidence `
      "$Prefix.reenumeration.json"
  try {
    Write-DurableJson $reenumerationPath $reenumeration
  } catch {
    $script:ExactUsbRoleReenumerationUnproven = $true
    $Record.reenumeration_proven = $false
    $Record.exact_usb_role_present = $false
    $Record.last_reenumeration_status =
        'FAIL_REENUMERATION_EVIDENCE_NOT_DURABLE'
    throw ('EXACT_USB_ROLE_REENUMERATION_UNPROVEN_AFTER_DEVICE_TARGETING_OPERATION: ' +
      "could not persist $Prefix re-enumeration evidence: " +
      $_.Exception.Message)
  }

  $processResultPath = Join-Path $evidence "$Prefix.process_result.json"
  if ($null -ne $capture -and $null -ne $capture.process_result -and
      (Test-Path -LiteralPath $processResultPath -PathType Leaf)) {
    $capture.process_result | Add-Member -NotePropertyName `
        reenumeration_evidence_path -NotePropertyValue $reenumerationPath -Force
    $capture.process_result | Add-Member -NotePropertyName `
        reenumeration_evidence_sha256 -NotePropertyValue `
        (Get-Sha256 $reenumerationPath) -Force
    Write-DurableJson $processResultPath $capture.process_result
  }
  $operationResult = [ordered]@{
    schema='vc-lora-esptool-operation-result-v1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    operation_prefix=$Prefix
    operation_kind=$Kind
    stub_mode=if ($Kind -ceq 'read_flash') {'rom_no_stub'}else{'stub'}
    baud=if ($Kind -ceq 'read_flash') {'115200'}else{'921600'}
    process_result_path=if (Test-Path -LiteralPath $processResultPath) {
      $processResultPath
    } else {$null}
    process_result_sha256=if (Test-Path -LiteralPath $processResultPath) {
      Get-Sha256 $processResultPath
    } else {$null}
    reenumeration_evidence_path=$reenumerationPath
    reenumeration_evidence_sha256=Get-Sha256 $reenumerationPath
  }
  Write-DurableJson (Join-Path $evidence "$Prefix.operation_result.json") `
      $operationResult

  if (-not [bool]$reenumeration.proven) {
    throw ('EXACT_USB_ROLE_REENUMERATION_UNPROVEN_AFTER_DEVICE_TARGETING_OPERATION: ' +
      "$($Role.name) exact USB COM/PNP identity was not present after " +
      "$Prefix; $($reenumeration.issue)")
  }
  if ($null -ne $operationFailure) {
    throw "$Prefix esptool invocation failed after proven re-enumeration: $operationFailure"
  }
  $capture
}

function Read-And-ProveRole([object]$Role, [object]$Record,
                            [int]$Sequence) {
  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_identity")
  $identity = Wait-RoleIdentity $Role
  Write-DurableJson (Join-Path $evidence `
      ('{0:D2}_{1}_identity.json' -f $Sequence,$Role.key)) $identity
  $Record.identity_verified = $true

  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_read_mac")
  $macResult = Invoke-DeviceEspTool ('{0:D2}_{1}_read_mac' -f `
      $Sequence,$Role.key) $Role $Record 'read_mac'
  Assert-Condition ($macResult.exit_code -eq 0) `
      "$($Role.name) read-mac failed"
  $combined = $macResult.stdout_text + $newline + $macResult.stderr_text
  $matches = [regex]::Matches($combined,
      '(?im)^\s*MAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
  $macs = @($matches | ForEach-Object {
      $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
  Assert-Condition ($macs.Count -eq 1 -and
      [string]$macs[0] -ceq [string]$Role.mac) `
      "$($Role.name) read-mac identity mismatch"
  $Record.read_mac_verified = $true

  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_verify_existing")
  $Record.pinned_verify_attempted = $true
  $verifyExisting = Invoke-DeviceEspTool `
      ('{0:D2}_{1}_verify_existing' -f $Sequence,$Role.key) `
      $Role $Record 'verify' $Role.stage
  $verifyCombined = $verifyExisting.stdout_text + $newline +
      $verifyExisting.stderr_text
  if ($verifyExisting.exit_code -eq 0 -and
      $verifyCombined.Contains('Verification successful (digest matched).')) {
    $Record.pinned_verify_matched = $true
    $Record.accepted_r18_proven = $true
    return
  }
  # A failed/malformed verify is transport-ambiguous. It never proves a flash
  # mismatch. Only the complete conservative ROM read below may do that.
  $Record.pinned_verify_failure_ambiguous = $true

  if ($script:OfflineFakeProcessMode -and
      $OfflineScenario -ceq 'fake_direct_unproven_write') {
    # Deliberately attempt the write function directly while mismatch remains
    # unproven. The in-function gate must reject it before a process starts.
    [void](Invoke-DeviceEspTool ('{0:D2}_{1}_forbidden_direct_write' -f `
        $Sequence,$Role.key) $Role $Record 'write' $Role.stage)
    throw 'Offline direct unproven-write probe unexpectedly returned'
  }

  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_readback")
  $readback = Join-Path $evidence `
      ('{0:D2}_{1}_initial_readback.application.bin' -f `
        $Sequence,$Role.key)
  $read = Invoke-DeviceEspTool ('{0:D2}_{1}_readback' -f `
      $Sequence,$Role.key) $Role $Record 'read_flash' $readback
  Assert-Condition ($read.exit_code -eq 0 -and
      (Test-Path -LiteralPath $readback -PathType Leaf) -and
      [int64](Get-Item -LiteralPath $readback).Length -eq [int64]$Role.bytes) `
      "$($Role.name) application readback failed; mismatch is unproven"
  $Record.readback_succeeded = $true
  $Record.readback_sha256 = Get-Sha256 $readback
  $Record.mismatch_proven =
      [string]$Record.readback_sha256 -cne [string]$Role.sha256

  if (-not $Record.mismatch_proven) {
    $Record.final_readback_succeeded = $true
    $Record.final_readback_sha256 = $Record.readback_sha256
    $Record.accepted_r18_proven = $true
    return
  }

  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_restore")
  $Record.restore_attempted = $true
  $write = Invoke-DeviceEspTool ('{0:D2}_{1}_restore' -f `
      $Sequence,$Role.key) $Role $Record 'write' $Role.stage
  Assert-Condition ($write.exit_code -eq 0 -and
      ($write.stdout_text + $write.stderr_text).Contains(
        'Hash of data verified.')) "$($Role.name) accepted R18 restore failed"
  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_verify_restore")
  $verify = Invoke-DeviceEspTool ('{0:D2}_{1}_verify' -f `
      $Sequence,$Role.key) $Role $Record 'verify' $Role.stage
  Assert-Condition ($verify.exit_code -eq 0 -and
      ($verify.stdout_text + $verify.stderr_text).Contains(
        'Verification successful (digest matched).')) `
      "$($Role.name) explicit accepted R18 verify failed"

  [void](Assert-ProcessGate "${Sequence}_$($Role.key)_final_readback")
  $finalReadback = Join-Path $evidence `
      ('{0:D2}_{1}_final_readback.application.bin' -f `
        $Sequence,$Role.key)
  $final = Invoke-DeviceEspTool ('{0:D2}_{1}_final_readback' -f `
      $Sequence,$Role.key) $Role $Record 'read_flash' $finalReadback
  Assert-Condition ($final.exit_code -eq 0 -and
      (Test-Path -LiteralPath $finalReadback -PathType Leaf) -and
      [int64](Get-Item -LiteralPath $finalReadback).Length -eq
        [int64]$Role.bytes) "$($Role.name) final readback failed"
  $Record.final_readback_succeeded = $true
  $Record.final_readback_sha256 = Get-Sha256 $finalReadback
  Assert-Condition ([string]$Record.final_readback_sha256 -ceq
      [string]$Role.sha256) "$($Role.name) final accepted R18 digest mismatch"
  $Record.restore_succeeded = $true
  $Record.accepted_r18_proven = $true
}

function Set-OfflineScenario([object[]]$Records, [string]$Scenario) {
  $operationRecords = if ($Scenario -eq 'restore_failure') {
    @($Records[0])
  } else {
    @($Records)
  }
  foreach ($record in $operationRecords) {
    $record.identity_verified = $true
    $record.read_mac_verified = $true
    $record.readback_succeeded = $true
    $record.readback_sha256 = $record.expected_application_sha256
    $record.final_readback_succeeded = $true
    $record.final_readback_sha256 = $record.expected_application_sha256
    $record.accepted_r18_proven = $true
  }
  if ($Scenario -eq 'identity_failure') {
    $Records[0].identity_verified = $false
    $Records[0].read_mac_verified = $false
    $Records[0].readback_succeeded = $false
    $Records[0].readback_sha256 = $null
    $Records[0].final_readback_succeeded = $false
    $Records[0].final_readback_sha256 = $null
    $Records[0].accepted_r18_proven = $false
    throw 'OFFLINE_INJECTED_IDENTITY_GATE_FAILURE'
  }
  if ($Scenario -eq 'read_failure') {
    $Records[0].readback_succeeded = $false
    $Records[0].readback_sha256 = $null
    $Records[0].final_readback_succeeded = $false
    $Records[0].final_readback_sha256 = $null
    $Records[0].accepted_r18_proven = $false
    $Records[0].device_operation_count = 2
    $Records[0].device_targeting_operation_entered = $true
    $Records[0].device_targeting_operation_attempted = $true
    $Records[0].hard_reset_requested = $true
    $Records[0].exact_usb_role_present = $true
    $Records[0].reenumeration_attempted = $true
    $Records[0].reenumeration_proven = $true
    $Records[0].last_reenumeration_status =
        'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST'
    $script:DeviceTargetingOperationEntered = $true
    $script:DeviceTargetingOperationAttempted = $true
    throw 'OFFLINE_INJECTED application readback failed after device execution'
  }
  if ($Scenario -in @('esptool_failure_reenumeration_success',
      'esptool_failure_reenumeration_failure',
      'marker_failure_reenumeration_success',
      'read_mac_mismatch_usb_role_proven')) {
    $Records[0].read_mac_verified = $false
    $Records[0].readback_succeeded = $false
    $Records[0].readback_sha256 = $null
    $Records[0].final_readback_succeeded = $false
    $Records[0].final_readback_sha256 = $null
    $Records[0].accepted_r18_proven = $false
    $Records[0].device_operation_count = 1
    $Records[0].device_targeting_operation_entered = $true
    $Records[0].device_targeting_operation_attempted = $true
    $Records[0].hard_reset_requested = $true
    $script:DeviceTargetingOperationEntered = $true
    $script:DeviceTargetingOperationAttempted = $true
    $Records[0].reenumeration_attempted = $true
    if ($Scenario -in @('esptool_failure_reenumeration_success',
        'marker_failure_reenumeration_success',
        'read_mac_mismatch_usb_role_proven')) {
      $Records[0].reenumeration_proven = $true
      $Records[0].exact_usb_role_present = $true
      $Records[0].last_reenumeration_status =
          'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST'
      if ($Scenario -eq 'read_mac_mismatch_usb_role_proven') {
        throw 'OFFLINE_INJECTED read-mac identity mismatch after device execution'
      }
      if ($Scenario -eq 'marker_failure_reenumeration_success') {
        throw 'OFFLINE_INJECTED expected esptool success marker was absent'
      }
      throw 'OFFLINE_INJECTED esptool invocation failed after device execution'
    }
    $Records[0].reenumeration_proven = $false
    $Records[0].exact_usb_role_present = $false
    $Records[0].last_reenumeration_status =
        'FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN'
    $script:ExactUsbRoleReenumerationUnproven = $true
    throw 'OFFLINE_INJECTED exact USB role re-enumeration failure'
  }
  if ($Scenario -in @('write_then_finalization_failure',
      'write_then_emergency_terminal_write_failure')) {
    $Records[0].readback_sha256 = ('0' * 64)
    $Records[0].mismatch_proven = $true
    $Records[0].restore_attempted = $true
    $Records[0].device_operation_count = 2
    $Records[0].device_targeting_operation_entered = $true
    $Records[0].device_targeting_operation_attempted = $true
    $Records[0].hard_reset_requested = $true
    $Records[0].exact_usb_role_present = $true
    $script:DeviceTargetingOperationEntered = $true
    $script:DeviceTargetingOperationAttempted = $true
    $Records[0].reenumeration_attempted = $true
    $Records[0].reenumeration_proven = $true
    $Records[0].last_reenumeration_status =
        'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST'
    $Records[0].accepted_r18_proven = $false
    $script:OfflineSimulatedDeviceExecution = $true
    $script:OfflineSimulatedWrite = $true
    $script:InjectFinalizationFailure = $true
    if ($Scenario -eq 'write_then_emergency_terminal_write_failure') {
      $script:InjectEmergencyTerminalWriteFailure = $true
    }
    return 'FAIL_RESTORE_PROVEN_MISMATCH_POWER_OFF_REQUIRED'
  }
  $mismatchKeys = switch ($Scenario) {
    'vehicle_mismatch' {@('vehicle')}
    'ground_mismatch' {@('ground')}
    'both_mismatch' {@('vehicle','ground')}
    'restore_failure' {@('vehicle')}
    default {@()}
  }
  foreach ($record in $operationRecords) {
    $record.device_operation_count = 3
    $record.device_targeting_operation_entered = $true
    $record.device_targeting_operation_attempted = $true
    $record.hard_reset_requested = $true
    $record.exact_usb_role_present = $true
    $record.reenumeration_attempted = $true
    $record.reenumeration_proven = $true
    $record.last_reenumeration_status =
        'PASS_EXACT_USB_ROLE_PRESENT_AFTER_HARD_RESET_REQUEST'
  }
  $script:DeviceTargetingOperationEntered = $true
  $script:DeviceTargetingOperationAttempted = $true
  foreach ($record in $Records) {
    if ($record.key -in $mismatchKeys) {
      $record.readback_sha256 = ('0' * 64)
      $record.mismatch_proven = $true
      $record.restore_attempted = $true
      if ($Scenario -eq 'restore_failure') {
        $record.restore_succeeded = $false
        $record.final_readback_succeeded = $false
        $record.final_readback_sha256 = $null
        $record.accepted_r18_proven = $false
      } else {
        $record.restore_succeeded = $true
        $record.device_operation_count = 5
      }
    }
  }
  if ($Scenario -eq 'restore_failure') {
    throw 'OFFLINE_INJECTED accepted R18 restore failure after proven mismatch'
  }
  if (@($mismatchKeys).Count -gt 0) {
    return 'PASS_R18_RESTORED_PROVEN_MISMATCH'
  }
  'PASS_R18_ALREADY_ACCEPTED_BOTH'
}

function Complete-Evidence([string]$Status, [object[]]$Records,
                           [bool]$AuthorizationConsumed,
                           [bool]$PowerOffRequired,
                           [string]$FailureMessage) {
  $summary = [pscustomobject][ordered]@{
    schema=$schema
    test_id=$testId
    started_utc=$startedUtc
    finished_utc=[DateTime]::UtcNow.ToString('o')
    status=$Status
    failure_message=$FailureMessage
    policy=[pscustomobject][ordered]@{
      application_only=$true;offset=$appOffset
      erase_allowed=$false;bootloader_write_allowed=$false
      partition_write_allowed=$false;merged_write_allowed=$false
      restore_only_after_successful_full_length_readback_mismatch=$true
      unproven_mismatch_never_writes=$true
      pinned_verify_first=$true
      verify_failure_is_transport_ambiguous=$true
      conservative_readback_stub_mode='rom_no_stub'
      conservative_readback_baud=115200
    }
    authorization=[pscustomobject][ordered]@{
      token=$authorizationText
      supplied=($HilAuthorization -ceq $authorizationText)
      consumed=$AuthorizationConsumed
      reusable=$false
    }
    authorization_consumed=$AuthorizationConsumed
    authorization_reusable=$false
    operator_safety_attestation_verified=
        ($OperatorSafetyAttestation -ceq $safetyText)
    roles=$Records
    process_gate='fail-closed before identity/read-mac/verify/readback/restore'
    device_targeting_operation_entered=
        [bool]$script:DeviceTargetingOperationEntered
    device_targeting_operation_attempted=
        [bool]$script:DeviceTargetingOperationAttempted
    application_liveness_proven=$false
    application_liveness_required_for_flash_content_reproof=$false
    external_actions=[pscustomobject]$script:ExternalActions
    esptool=[pscustomobject][ordered]@{
      version=$expectedEspToolVersion;sha256=$expectedEspToolSha256
    }
    power_off_required=$PowerOffRequired
    offline_contract_test=$OfflineContractTest.IsPresent
    live_flash_authorized=$false
  }
  $summaryPath = Join-Path $evidence 'summary.json'
  Write-DurableJson $summaryPath $summary
  $manifestFiles = @(Get-ChildItem -LiteralPath $evidence -File -Recurse |
    Sort-Object FullName | Where-Object {
      $relative = $_.FullName.Substring($evidence.Length).
          TrimStart([char[]]@('\','/')).Replace('\','/')
      $relative -notin @('SHA256SUMS.txt','final_seal.json')
    })
  $manifestPaths = New-Object 'Collections.Generic.List[string]'
  $entries = @($manifestFiles | ForEach-Object {
    $relative = $_.FullName.Substring($evidence.Length).
        TrimStart([char[]]@('\','/')).Replace('\','/')
    Assert-Condition (-not [IO.Path]::IsPathRooted($relative) -and
        $relative -notmatch '(^|/)\.\.(/|$)') `
        "Unsafe evidence manifest path: $relative"
    [void]$manifestPaths.Add($relative)
    (Get-Sha256 $_.FullName) + '  ' + $relative
  })
  $canonicalManifestPaths = [string[]]@($manifestPaths)
  [Array]::Sort($canonicalManifestPaths,[StringComparer]::Ordinal)
  $canonicalManifestPathText =
      ($canonicalManifestPaths -join "`n") + "`n"
  $manifestPathSetSha256 = Get-TextSha256 $canonicalManifestPathText
  $sumsPath = Join-Path $evidence 'SHA256SUMS.txt'
  Write-DurableText $sumsPath (($entries -join $newline) + $newline)
  $actualPaths = @(Get-ChildItem -LiteralPath $evidence -File -Recurse |
    ForEach-Object {
      $_.FullName.Substring($evidence.Length).
          TrimStart([char[]]@('\','/')).Replace('\','/')
    } | Where-Object {$_ -notin @('SHA256SUMS.txt','final_seal.json')})
  $manifestPathSet = New-Object 'Collections.Generic.HashSet[string]' `
      ([StringComparer]::OrdinalIgnoreCase)
  foreach ($relative in $manifestPaths) {
    Assert-Condition ($manifestPathSet.Add($relative)) `
        "Duplicate evidence manifest path: $relative"
  }
  $actualPathSet = New-Object 'Collections.Generic.HashSet[string]' `
      ([StringComparer]::OrdinalIgnoreCase)
  foreach ($relative in $actualPaths) {
    Assert-Condition ($actualPathSet.Add($relative)) `
        "Duplicate actual evidence path: $relative"
  }
  Assert-Condition ($manifestPathSet.Count -eq $actualPathSet.Count) `
      'Evidence manifest and actual file counts differ before sealing'
  foreach ($relative in $manifestPaths) {
    Assert-Condition ($actualPathSet.Contains($relative)) `
        "Evidence manifest differs from actual file set: $relative"
  }
  $seal = [pscustomobject][ordered]@{
    schema='vc-lora-accepted-r18-reproof-final-seal-v1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    status=$Status
    summary_sha256=Get-Sha256 $summaryPath
    sha256sums_sha256=Get-Sha256 $sumsPath
    manifest_entry_count=[int]$manifestPaths.Count
    manifest_path_set_sha256=$manifestPathSetSha256
    authorization_consumed=$AuthorizationConsumed
    authorization_reusable=$false
    accepted_r18_proven_roles=@($Records | Where-Object {
      $_.accepted_r18_proven } | ForEach-Object {$_.key})
    power_off_required=$PowerOffRequired
  }
  if ($script:InjectFinalizationFailure) {
    throw 'OFFLINE_INJECTED_FINAL_SEAL_FAILURE_AFTER_WRITE'
  }
  Write-DurableJson (Join-Path $evidence 'final_seal.json') $seal
  $summary
}

function Write-EmergencyTerminal([string]$FinalizationFailure,
                                 [object[]]$Records,
                                 [bool]$AuthorizationConsumed) {
  if ($script:InjectEmergencyTerminalWriteFailure) {
    throw 'OFFLINE_INJECTED_EMERGENCY_TERMINAL_WRITE_FAILURE'
  }
  $record = [pscustomobject][ordered]@{
    schema='vc-lora-accepted-r18-emergency-terminal-v1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    status='FAIL_EVIDENCE_FINALIZATION_POWER_OFF_REQUIRED'
    failure_message=$FinalizationFailure
    power_off_required=$true
    fail_closed=$true
    authorization_consumed=$AuthorizationConsumed
    authorization_reusable=$false
    device_targeting_operation_entered=
        [bool]$script:DeviceTargetingOperationEntered
    device_targeting_operation_attempted=
        [bool]$script:DeviceTargetingOperationAttempted
    application_liveness_proven=$false
    application_liveness_required_for_flash_content_reproof=$false
    external_actions=[pscustomobject]$script:ExternalActions
    offline_contract_test=$OfflineContractTest.IsPresent
    offline_simulated_device_execution=
        [bool]$script:OfflineSimulatedDeviceExecution
    offline_simulated_write=[bool]$script:OfflineSimulatedWrite
    roles=$Records
  }
  $path = Join-Path $evidence 'emergency_terminal.json'
  $json = ($record | ConvertTo-Json -Depth 20) + $newline
  try {
    Write-DurableText $path $json
  } catch {
    # Independent last-resort path: avoid dependence on the normal evidence
    # writer whose failure caused this terminal path.
    [IO.File]::WriteAllText($path, $json, $utf8)
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
  }
  $hash = Get-Sha256 $path
  $hashPath = Join-Path $evidence 'emergency_terminal.sha256'
  $hashText = $hash + '  emergency_terminal.json' + $newline
  try {
    Write-DurableText $hashPath $hashText
  } catch {
    [IO.File]::WriteAllText($hashPath, $hashText, $utf8)
  }
  $record
}

function ConvertTo-TerminalMarkerValue([object]$Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return '<none>'
  }
  ([string]$Value).Replace("`r", ' ').Replace("`n", ' ').Replace(';', ',')
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
      [Guid]::NewGuid().ToString('N').Substring(0,8)
  $EvidenceDirectory = Join-Path $repo `
      "runs\validation\$testId\$runId"
}
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
Assert-Condition (-not (Test-Path -LiteralPath $evidence)) `
    'Evidence directory already exists; one-run evidence may not be reused'
New-Item -ItemType Directory -Path $evidence | Out-Null

$rolePins = @(
  [pscustomobject][ordered]@{
    key='vehicle';name='Vehicle';port='COM3'
    pnp='USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
    parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
    mac='90:70:69:11:81:a4';bytes=[int64]389280
    sha256='9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
    leaf='vehicle.application.bin';stage=$null
  },
  [pscustomobject][ordered]@{
    key='ground';name='Ground';port='COM6'
    pnp='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
    parent='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
    mac='1c:db:d4:5a:83:80';bytes=[int64]360208
    sha256='30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5'
    leaf='ground.application.bin';stage=$null
  }
)
$records = @($rolePins | ForEach-Object { New-RoleRecord $_ })
$script:ExternalActions = [ordered]@{
  device_access_attempted=$false
  process_inventory_queried=$false
  esptool_executed=$false
  firmware_write_attempted=$false
  firmware_may_have_changed=$false
  erase_performed=$false
  bootloader_written=$false
  partition_table_written=$false
  merged_image_written=$false
}
$script:ProcessGateSequence = 0
$script:ExactUsbRoleReenumerationUnproven = $false
$script:DeviceTargetingOperationEntered = $false
$script:DeviceTargetingOperationAttempted = $false
$script:OfflineSimulatedDeviceExecution = $false
$script:OfflineSimulatedWrite = $false
$script:InjectFinalizationFailure = $false
$script:InjectEmergencyTerminalWriteFailure = $false
$script:OfflineFakeProcessMode = $false
$script:OfflineFakeEspToolScriptPath = $null
$locks = [Collections.ArrayList]::new()
$status = 'FAIL_CLOSED'
$failureMessage = $null
$powerOffRequired = $false
$authorizationConsumed = $false

if (-not $Execute) {
  Complete-Evidence 'DRY_RUN_NO_DEVICE_ACCESS' $records $false $false $null |
      Write-Output
  return
}

$authorizationConsumed = $true
try {
  Assert-Condition ($HilAuthorization -ceq $authorizationText) `
      'Exact one-run R18 reproof authorization is required'
  Assert-Condition ($OperatorSafetyAttestation -ceq $safetyText) `
      'Exact six-item operator safety attestation is required'

  $fakeProcessScenarios = @(
    'fake_verify_match',
    'fake_read_midstream_failure',
    'fake_read_wrong_size_exit0',
    'fake_read_full_match',
    'fake_read_full_mismatch',
    'fake_direct_unproven_write',
    'fake_read_full_match_spaced_paths')
  if ($OfflineContractTest -and $OfflineScenario -in $fakeProcessScenarios) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace(
        $OfflineFakeEspToolScript)) `
        'Offline fake-esptool script is required for fake process scenarios'
    $script:OfflineFakeEspToolScriptPath = (Resolve-Path -LiteralPath `
        $OfflineFakeEspToolScript -ErrorAction Stop).Path
    $script:OfflineFakeProcessMode = $true
    $acceptedRoot = Join-Path $repo `
        'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts'
    $stageRoot = Join-Path $evidence 'staged'
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    foreach ($role in $rolePins) {
      $source = Join-Path $acceptedRoot $role.leaf
      $role.stage = Join-Path $stageRoot `
          "accepted_r18_$($role.key).application.bin"
      Copy-PinnedToStage $source $role.stage $role.sha256 $role.bytes
      [void]$locks.Add((Open-PinnedReadLock $role.stage $role.sha256))
    }
    [void](Assert-ProcessGate 'before_any_device_access')
    $version = Invoke-EspTool '00_esptool_version' $rolePins[0] 'version'
    Assert-Condition ($version.exit_code -eq 0 -and
        ($version.stdout_text + $version.stderr_text) -match
          [regex]::Escape($expectedEspToolVersion)) `
        'Fake esptool did not report the expected 5.3.1 version'
    for ($i = 0; $i -lt $rolePins.Count; $i++) {
      $record = $records[$i]
      try {
        Read-And-ProveRole $rolePins[$i] $record ($i + 1)
      } catch {
        $record.issues = @($record.issues) + $_.Exception.Message
        throw
      }
    }
    if (@($records | Where-Object {$_.mismatch_proven}).Count -gt 0) {
      $status = 'PASS_R18_RESTORED_PROVEN_MISMATCH'
    } else {
      $status = 'PASS_R18_ALREADY_ACCEPTED_BOTH'
    }
  } elseif ($OfflineContractTest) {
    $status = Set-OfflineScenario $records $OfflineScenario
    $powerOffRequired = $status -in @(
      'FAIL_RESTORE_PROVEN_MISMATCH_POWER_OFF_REQUIRED',
      'FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN_POWER_OFF_REQUIRED')
  } else {
    $acceptedRoot = Join-Path $repo `
        'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts'
    $stageRoot = Join-Path $evidence 'staged'
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    foreach ($role in $rolePins) {
      $source = Join-Path $acceptedRoot $role.leaf
      $role.stage = Join-Path $stageRoot `
          "accepted_r18_$($role.key).application.bin"
      Copy-PinnedToStage $source $role.stage $role.sha256 $role.bytes
      [void]$locks.Add((Open-PinnedReadLock $role.stage $role.sha256))
    }
    $espSource = Join-Path $repo `
        'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001\20260914T131232863Z-f70bdf89\staged\esptool-5.3.1.exe'
    $script:EspToolPath = Join-Path $stageRoot 'esptool-5.3.1.exe'
    $espBytes = (Get-Item -LiteralPath $espSource -ErrorAction Stop).Length
    Copy-PinnedToStage $espSource $script:EspToolPath `
        $expectedEspToolSha256 $espBytes
    [void]$locks.Add((Open-PinnedReadLock $script:EspToolPath `
        $expectedEspToolSha256))

    [void](Assert-ProcessGate 'before_any_device_access')
    $version = Invoke-EspTool '00_esptool_version' $rolePins[0] 'version'
    Assert-Condition ($version.exit_code -eq 0 -and
        ($version.stdout_text + $version.stderr_text) -match
          [regex]::Escape($expectedEspToolVersion)) `
        'Pinned esptool did not report the expected 5.3.1 version'

    for ($i = 0; $i -lt $rolePins.Count; $i++) {
      $record = $records[$i]
      try {
        Read-And-ProveRole $rolePins[$i] $record ($i + 1)
      } catch {
        $record.issues = @($record.issues) + $_.Exception.Message
        throw
      }
    }
    if (@($records | Where-Object {$_.mismatch_proven}).Count -gt 0) {
      $status = 'PASS_R18_RESTORED_PROVEN_MISMATCH'
    } else {
      $status = 'PASS_R18_ALREADY_ACCEPTED_BOTH'
    }
  }
} catch {
  $failureMessage = $_.Exception.Message
  $restores = @($records | Where-Object {$_.restore_attempted})
  $unproven = @($records | Where-Object {
      -not $_.readback_succeeded -and -not $_.mismatch_proven })
  if ($script:ExactUsbRoleReenumerationUnproven) {
    $status = 'FAIL_EXACT_USB_ROLE_REENUMERATION_UNPROVEN_POWER_OFF_REQUIRED'
    $powerOffRequired = $true
  } elseif ($script:ExternalActions.firmware_write_attempted -or
      @($restores | Where-Object {-not $_.accepted_r18_proven}).Count -gt 0) {
    $status = 'FAIL_RESTORE_PROVEN_MISMATCH_POWER_OFF_REQUIRED'
    $powerOffRequired = $true
  } elseif ($script:DeviceTargetingOperationAttempted) {
    $status = 'FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE'
  } elseif ($failureMessage -match '(?i)identity|read-mac|serial device') {
    $status = 'FAIL_IDENTITY_GATE_NO_DEVICE_TARGETING_OPERATION'
  } elseif ($unproven.Count -gt 0) {
    $status = 'FAIL_READBACK_UNPROVEN_NO_WRITE'
  } elseif ($script:DeviceTargetingOperationEntered) {
    $status = 'FAIL_DEVICE_TARGETING_OPERATION_NOT_ATTEMPTED_NO_WRITE'
  } else {
    $status = 'FAIL_CLOSED_NO_UNPROVEN_WRITE'
  }
} finally {
  foreach ($lock in $locks) {
    try { $lock.Dispose() } catch {}
  }
}

$summary = $null
try {
  $summary = Complete-Evidence $status $records $authorizationConsumed `
      $powerOffRequired $failureMessage
  $summary | Write-Output
} catch {
  $finalizationFailure = $_.Exception.Message
  $powerOffRequired = $true
  try {
    $emergency = Write-EmergencyTerminal $finalizationFailure $records `
        $authorizationConsumed
    $emergency | Write-Output
    exit 1
  } catch {
    $emergencyFailure = $_.Exception.Message
    $marker = 'VC_LORA_UNAVOIDABLE_TERMINAL_MARKER POWER_OFF_REQUIRED ' +
        'status=FAIL_EMERGENCY_TERMINAL_WRITE_POWER_OFF_REQUIRED ' +
        'original_error=' + (ConvertTo-TerminalMarkerValue $failureMessage) +
        ' finalization_error=' +
        (ConvertTo-TerminalMarkerValue $finalizationFailure) +
        ' emergency_error=' +
        (ConvertTo-TerminalMarkerValue $emergencyFailure)
    try {
      Write-Error -Message $marker -ErrorAction Continue
    } catch {
      try { [Console]::Error.WriteLine($marker) } catch {}
    }
    exit 2
  }
}
if ($status -notmatch '^PASS_') { exit 1 }
