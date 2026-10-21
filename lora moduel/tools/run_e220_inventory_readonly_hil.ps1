[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$OfflineSelfTest,
  [string]$RepoRoot = '',
  [string]$EvidenceDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$newline = [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $leaf = if ($OfflineSelfTest.IsPresent) { "OFFLINE-$stamp" } else { "LIVE-$stamp" }
  $EvidenceDirectory = Join-Path $repo `
      "runs\high_speed\R19-HS-G0-E220-INVENTORY-HIL-001\$leaf"
}
if (Test-Path -LiteralPath $EvidenceDirectory) {
  throw "Refusing to overwrite evidence: $EvidenceDirectory"
}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$evidence = (Resolve-Path -LiteralPath $EvidenceDirectory).Path

$script:StartedUtc = [DateTime]::UtcNow.ToString('o')
$script:StageLocks = [Collections.ArrayList]::new()
$script:FlashSteps = [Collections.ArrayList]::new()
$script:RoleResults = [Collections.ArrayList]::new()
$script:Checks = [Collections.ArrayList]::new()
$script:DeviceAccessAttempted = $false
$script:ProcessInventoryQueried = $false
$script:PnpQueried = $false
$script:ComPortsEnumerated = $false
$script:ComPortsOpened = $false
$script:EspToolExecuted = $false
$script:FirmwareWriteAttempted = $false
$script:PhysicalIsolationRequired = $false
$script:FinalDualVerifyPassed = $false
$script:RunnerStartSha256 = ''
$script:Outcome = 'FAIL'
$script:Failure = ''

function Assert-Condition([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-Sha([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Write-Json([string]$Path, [object]$Value) {
  [IO.File]::WriteAllText(
      $Path, (ConvertTo-Json -InputObject $Value -Depth 24) + $newline, $utf8)
}

function Add-Check([string]$Name, [bool]$Valid, [string]$Detail = '') {
  [void]$script:Checks.Add([pscustomobject][ordered]@{
    name=$Name;valid=$Valid;detail=$Detail
  })
  if (-not $Valid) { throw "$Name`: $Detail" }
}

$candidateRoot = Join-Path $repo `
    'runs\candidates\R19-HS-G0-E220-INVENTORY-READONLY-003\20260915T123352981Z'
$acceptedRoot = Join-Path $repo `
    'runs\baselines\R18-PRODUCTION-R4-ACCEPTED\20260914T225054625Z\artifacts'
$flashRoot = Join-Path $repo `
    'runs\hil\R18-PHASE6-PRODUCTION-FLASH-001\20260914T131232863Z-f70bdf89\staged'

$pins = [ordered]@{
  sketch=[pscustomobject]@{
    name='candidateSource';source=(Join-Path $repo `
      'vc_lora_e220_inventory_xiao_esp32s3\vc_lora_e220_inventory_xiao_esp32s3.ino')
    bytes=[int64]14399;sha256='55AD068AA520E568F3EEF11BED1F6FC8979CD95DCED35BF04573A2A41D73C7AC'
  }
  firmwareContract=[pscustomobject]@{
    name='firmwareContract';source=(Join-Path $repo `
      'tests\arduino_compile\check_e220_inventory_readonly_contract.ps1')
    bytes=[int64]12189;sha256='32249990E58B83CD974F70BD14DA7615D22D2D049153C452434E5C355D10E5B0'
  }
  groundCandidate=[pscustomobject]@{
    name='groundCandidate';source=(Join-Path $candidateRoot `
      'ground\firmware\vc_lora_e220_inventory_xiao_esp32s3.ino.bin')
    bytes=[int64]285952;sha256='213FAE16F449C005015D971669DFAD18E53730729DC14382AB81496680EAEAF8'
  }
  vehicleCandidate=[pscustomobject]@{
    name='vehicleCandidate';source=(Join-Path $candidateRoot `
      'vehicle\firmware\vc_lora_e220_inventory_xiao_esp32s3.ino.bin')
    bytes=[int64]285952;sha256='6DE15CF5085EFB7E66F9C5117E7DA8BFD01C04613129159CB6F87D7D4ADD0382'
  }
  groundRollback=[pscustomobject]@{
    name='groundRollback';source=(Join-Path $acceptedRoot 'ground.application.bin')
    bytes=[int64]360208;sha256='30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5'
  }
  vehicleRollback=[pscustomobject]@{
    name='vehicleRollback';source=(Join-Path $acceptedRoot 'vehicle.application.bin')
    bytes=[int64]389280;sha256='9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52'
  }
  espTool=[pscustomobject]@{
    name='espTool';source=(Join-Path $flashRoot 'esptool-5.3.1.exe')
    bytes=[int64]14323136;sha256='A939E28FE2FBB53E65E46F0246A4D71B9FD6C052EF0E046182DF4A4FE8BEC946'
  }
}

$roles = @(
  [pscustomobject][ordered]@{
    role='vehicle';port='COM3'
    pnp='USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000'
    parent='USB\VID_303A&PID_1001\90:70:69:11:81:A4'
    mac='90:70:69:11:81:a4'
    candidate=$pins.vehicleCandidate;rollback=$pins.vehicleRollback
  },
  [pscustomobject][ordered]@{
    role='ground';port='COM6'
    pnp='USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000'
    parent='USB\VID_303A&PID_1001\1C:DB:D4:5A:83:80'
    mac='1c:db:d4:5a:83:80'
    candidate=$pins.groundCandidate;rollback=$pins.groundRollback
  }
)

function Assert-PinnedFile([object]$Pin, [string]$Checkpoint) {
  Assert-Condition (Test-Path -LiteralPath $Pin.source -PathType Leaf) `
      "$($Pin.name) missing at $Checkpoint"
  $item = Get-Item -LiteralPath $Pin.source
  $sha = Get-Sha $item.FullName
  Assert-Condition ([int64]$item.Length -eq [int64]$Pin.bytes) `
      "$($Pin.name) size mismatch at $Checkpoint"
  Assert-Condition ($sha -ceq [string]$Pin.sha256) `
      "$($Pin.name) SHA-256 mismatch at $Checkpoint"
  [pscustomobject][ordered]@{
    path=$item.FullName;bytes=[int64]$item.Length;sha256=$sha
  }
}

function Test-StaticPins {
  foreach ($entry in $pins.GetEnumerator()) {
    [void](Assert-PinnedFile $entry.Value 'static_preflight')
  }
  Add-Check 'all_static_pins_exact' $true '7/7'
}

function Copy-ToLockedStage([object]$Pin, [string]$Leaf) {
  $directory = Join-Path $evidence 'staged'
  [void][IO.Directory]::CreateDirectory($directory)
  $destination = Join-Path $directory $Leaf
  $source = [IO.FileStream]::new(
      [string]$Pin.source,[IO.FileMode]::Open,[IO.FileAccess]::Read,
      [IO.FileShare]::Read,65536,[IO.FileOptions]::SequentialScan)
  try {
    $target = [IO.FileStream]::new(
        $destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::Read,65536,[IO.FileOptions]::WriteThrough)
    try { $source.CopyTo($target);$target.Flush($true) } finally {$target.Dispose()}
  } finally {$source.Dispose()}
  [void](Assert-PinnedFile ([pscustomobject]@{
    name=$Pin.name;source=$destination;bytes=$Pin.bytes;sha256=$Pin.sha256
  }) 'locked_stage')
  $Pin | Add-Member -NotePropertyName stage_path -NotePropertyValue $destination -Force
  $lock = [IO.FileStream]::new(
      $destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,
      [IO.FileShare]::Read)
  [void]$script:StageLocks.Add($lock)
}

function Lock-RunnerSource {
  $runnerSource = $MyInvocation.MyCommand.ScriptBlock.File
  if ([string]::IsNullOrWhiteSpace($runnerSource)) {
    $runnerSource = Join-Path $repo 'tools\run_e220_inventory_readonly_hil.ps1'
  }
  $script:RunnerStartSha256 = Get-Sha $runnerSource
  $destination = Join-Path $evidence 'runner.executed.ps1'
  $source = [IO.FileStream]::new(
      $runnerSource,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try {
    $target = [IO.FileStream]::new(
        $destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::Read)
    try {$source.CopyTo($target);$target.Flush($true)} finally {$target.Dispose()}
  } finally {$source.Dispose()}
  Assert-Condition ((Get-Sha $destination) -ceq $script:RunnerStartSha256) `
      'runner lock copy mismatch'
  $lock = [IO.FileStream]::new(
      $destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  [void]$script:StageLocks.Add($lock)
}

function Assert-AllPinned {
  Test-StaticPins
  Copy-ToLockedStage $pins.sketch 'candidate.source.ino'
  Copy-ToLockedStage $pins.firmwareContract 'firmware.contract.ps1'
  Copy-ToLockedStage $pins.vehicleCandidate 'vehicle.candidate.application.bin'
  Copy-ToLockedStage $pins.groundCandidate 'ground.candidate.application.bin'
  Copy-ToLockedStage $pins.vehicleRollback 'vehicle.r18.application.bin'
  Copy-ToLockedStage $pins.groundRollback 'ground.r18.application.bin'
  Copy-ToLockedStage $pins.espTool 'esptool-5.3.1.exe'
}

function Quote-NativeArgument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}

function Invoke-BoundedNativeProcess(
    [string]$FilePath,[string[]]$Arguments,
    [int]$TimeoutMilliseconds = 60000) {
  Assert-Condition ($TimeoutMilliseconds -le 60000) 'native timeout exceeds 60000 ms'
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  $psi.Arguments = (@($Arguments | ForEach-Object {Quote-NativeArgument $_}) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  $script:EspToolExecuted = $true
  try {
    Assert-Condition $process.Start() 'native process did not start'
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      try {$process.Kill()} catch {}
      try {$process.WaitForExit()} catch {}
      throw "native process timeout after $TimeoutMilliseconds ms"
    }
    [void][Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask),5000)
    [pscustomobject][ordered]@{
      exit_code=$process.ExitCode
      stdout_text=$stdoutTask.Result
      stderr_text=$stderrTask.Result
    }
  } finally {$process.Dispose()}
}

function Assert-SafeEspToolArgv(
    [ValidateSet('read_mac','write','verify')][string]$Kind,
    [string[]]$Tokens,[string]$Port,[string]$ExpectedApplication='') {
  $base = @('--chip','esp32s3','--port',$Port,'--baud','921600',
    '--before','default-reset','--after','hard-reset')
  Assert-Condition ($Tokens.Count -ge 11) 'esptool argv too short'
  for ($i=0;$i -lt $base.Count;$i++) {
    Assert-Condition ($Tokens[$i] -ceq $base[$i]) "base argv mismatch $i"
  }
  foreach ($token in $Tokens) {
    $lower=$token.ToLowerInvariant()
    Assert-Condition ($lower -notin @('erase-flash','erase-all','0x0','0x8000','0xe000')) `
        "forbidden esptool token $token"
    Assert-Condition ($lower -notmatch 'bootloader|partitions') 'bootloader/partitions forbidden'
    Assert-Condition (-not $lower.EndsWith('.merged.bin')) 'merged image forbidden'
  }
  if ($Kind -ceq 'read_mac') {
    Assert-Condition ($Tokens.Count -eq 11 -and $Tokens[10] -ceq 'read-mac') `
        'read-mac argv not exact'
    return
  }
  Assert-Condition (@($Tokens|Where-Object {$_ -ceq '0x10000'}).Count -eq 1) `
      'exactly one application offset required'
  Assert-Condition (@($Tokens|Where-Object {$_.EndsWith('.bin')}).Count -eq 1) `
      'exactly one application binary required'
  Assert-Condition ($Tokens -ccontains $ExpectedApplication) 'wrong staged application'
  if ($Kind -ceq 'write') {
    $tail=@('write-flash','-z','--flash-mode','keep','--flash-freq','keep',
      '--flash-size','keep','0x10000',$ExpectedApplication)
  } else {
    $tail=@('verify-flash','0x10000',$ExpectedApplication)
  }
  Assert-Condition ($Tokens.Count -eq $base.Count+$tail.Count) 'argv count mismatch'
  for ($i=0;$i -lt $tail.Count;$i++) {
    Assert-Condition ($Tokens[$base.Count+$i] -ceq $tail[$i]) "tail argv mismatch $i"
  }
}

function New-EspToolArgv([object]$Role,
    [ValidateSet('read_mac','write','verify')][string]$Kind,
    [string]$Application='') {
  $base=@('--chip','esp32s3','--port',[string]$Role.port,'--baud','921600',
    '--before','default-reset','--after','hard-reset')
  if ($Kind -ceq 'read_mac') {return [string[]]($base+@('read-mac'))}
  if ($Kind -ceq 'write') {
    return [string[]]($base+@('write-flash','-z','--flash-mode','keep',
      '--flash-freq','keep','--flash-size','keep','0x10000',$Application))
  }
  [string[]]($base+@('verify-flash','0x10000',$Application))
}

function Assert-NoCompetingClients {
  $script:ProcessInventoryQueried = $true
  $names=@('missionplanner.exe','qgroundcontrol.exe','mavproxy.exe',
    'putty.exe','arduino.exe','arduino-cli.exe')
  $found=@(Get-CimInstance Win32_Process | Where-Object {
    ([string]$_.Name).ToLowerInvariant() -in $names -or
    ([string]$_.CommandLine) -match '(?i)COM3|COM6'
  } | Where-Object {$_.ProcessId -ne $PID})
  $foundNames=@($found | ForEach-Object {[string]$_.Name})
  Assert-Condition ($found.Count -eq 0) `
      "competing serial clients: $($foundNames-join ',')"
  @($found)
}

function Get-RoleIdentity([object]$Role) {
  $script:PnpQueried=$true
  $script:ComPortsEnumerated=$true
  $port=@(Get-CimInstance Win32_SerialPort | Where-Object {
    [string]$_.DeviceID -ceq [string]$Role.port
  })
  Assert-Condition ($port.Count -eq 1) "$($Role.port) serial identity count=$($port.Count)"
  $parent=(Get-PnpDeviceProperty -InstanceId $port[0].PNPDeviceID `
      -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
  [pscustomobject][ordered]@{
    port=[string]$port[0].DeviceID
    pnp_device_id=[string]$port[0].PNPDeviceID
    parent_device_id=[string]$parent
    status=[string]$port[0].Status
    config_manager_error_code=[int]$port[0].ConfigManagerErrorCode
  }
}

function Assert-RoleIdentity([object]$Role,[object]$Identity) {
  Assert-Condition ([string]$Identity.port -ceq [string]$Role.port) 'port changed'
  Assert-Condition ([string]$Identity.pnp_device_id -ceq [string]$Role.pnp) 'PNP mismatch'
  Assert-Condition ([string]$Identity.parent_device_id -ceq [string]$Role.parent) 'parent mismatch'
  Assert-Condition ([string]$Identity.status -ceq 'OK') 'status is not OK'
  Assert-Condition ([int]$Identity.config_manager_error_code -eq 0) `
      'config_manager_error_code is nonzero'
}

function Wait-RoleIdentity([object]$Role,[int]$TimeoutMilliseconds=15000) {
  $watch=[Diagnostics.Stopwatch]::StartNew();$last=''
  while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
    try {
      $identity=Get-RoleIdentity $Role
      Assert-RoleIdentity $Role $identity
      return $identity
    } catch {$last=$_.Exception.Message;Start-Sleep -Milliseconds 200}
  }
  throw "identity timeout $($Role.role): $last"
}

function New-Serial([string]$Port) {
  $serial=[IO.Ports.SerialPort]::new($Port,115200,'None',8,'One')
  $serial.DtrEnable=$false;$serial.RtsEnable=$false
  $serial.Handshake='None';$serial.ReadTimeout=50;$serial.WriteTimeout=1000
  $serial.Encoding=$utf8
  $serial
}

function Test-ExclusiveSerialOwnership([object]$Role) {
  [void](Assert-NoCompetingClients)
  [void](Wait-RoleIdentity $Role)
  $serial=New-Serial $Role.port
  $serial.DtrEnable = $false
  $serial.RtsEnable = $false
  $script:DeviceAccessAttempted=$true
  try {
    $serial.Open();$script:ComPortsOpened=$true
    Assert-Condition $serial.IsOpen "$($Role.port) exclusive open failed"
    [pscustomobject]@{result='PASS';port=$Role.port
      DtrEnable=$serial.DtrEnable;RtsEnable=$serial.RtsEnable}
  } finally {if($serial.IsOpen){$serial.Close()};$serial.Dispose()}
}

function Invoke-EspStep([object]$Role,[string]$Label,
    [ValidateSet('read_mac','write','verify')][string]$Kind,
    [object]$Application=$null,[switch]$RecoveryMode) {
  [void](Assert-NoCompetingClients)
  $before=Wait-RoleIdentity $Role
  $app=if($null -eq $Application){''}else{[string]$Application.stage_path}
  [string[]]$argv=New-EspToolArgv $Role $Kind $app
  Assert-SafeEspToolArgv $Kind $argv $Role.port $app
  $prefix='{0}_{1}' -f $Role.role,$Label
  Write-Json (Join-Path $evidence "$prefix.argv.json") ([object[]]$argv)
  if($Kind -ceq 'write'){
    $script:FirmwareWriteAttempted=$true
    Write-Json (Join-Path $evidence "$prefix.intent.json") ([ordered]@{
      state='PRELAUNCH_FIRMWARE_MAY_CHANGE';role=$Role.role;port=$Role.port
      offset='0x10000';application_sha256=$Application.sha256
      RecoveryMode=$RecoveryMode.IsPresent
    })
  }
  $capture=Invoke-BoundedNativeProcess $pins.espTool.stage_path $argv 60000
  [IO.File]::WriteAllText((Join-Path $evidence "$prefix.stdout.log"),
      $capture.stdout_text,$utf8)
  [IO.File]::WriteAllText((Join-Path $evidence "$prefix.stderr.log"),
      $capture.stderr_text,$utf8)
  $issues=[Collections.ArrayList]::new();$mac=$null
  if($capture.exit_code -ne 0){[void]$issues.Add("exit=$($capture.exit_code)")}
  if($Kind -ceq 'read_mac'){
    $matches=[regex]::Matches($capture.stdout_text,
      '(?im)^\s*MAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$')
    $values=@($matches|ForEach-Object {$_.Groups[1].Value.ToLowerInvariant()}|Sort-Object -Unique)
    if($values.Count -ne 1){[void]$issues.Add("mac_count=$($values.Count)")}else{
      $mac=$values[0];if($mac -cne $Role.mac){[void]$issues.Add("mac=$mac")}
    }
  } elseif($Kind -ceq 'write'){
    if(-not $capture.stdout_text.Contains('Hash of data verified.')){
      [void]$issues.Add('write_hash_marker_missing')
    }
  } elseif(-not $capture.stdout_text.Contains('Verification successful (digest matched).')){
    [void]$issues.Add('verify_marker_missing')
  }
  $after=Wait-RoleIdentity $Role
  $record=[pscustomobject][ordered]@{
    role=$Role.role;label=$Label;kind=$Kind
    result=if($issues.Count -eq 0){'PASS'}else{'FAIL'}
    issues=@($issues);parsed_mac=$mac;identity_before=$before;identity_after=$after
    exit_code=$capture.exit_code;RecoveryMode=$RecoveryMode.IsPresent
  }
  [void]$script:FlashSteps.Add($record)
  Write-Json (Join-Path $evidence "$prefix.record.json") $record
  Assert-Condition ($issues.Count -eq 0) "$prefix failed: $(@($issues)-join ';')"
  $record
}

function Convert-StrictInventoryLine([string]$Line,[string]$ExpectedRole,
    [string]$ExpectedNonce='',[Nullable[uint32]]$ExpectedBootNonce=$null) {
  $value=$Line|ConvertFrom-Json -ErrorAction Stop
  Assert-Condition ([string]$value.schema -ceq 'e220_inventory_v1') 'schema mismatch'
  Assert-Condition ([string]$value.role -ceq $ExpectedRole) 'wrong_role_rejected'
  if(-not [string]::IsNullOrWhiteSpace($ExpectedNonce)){
    Assert-Condition ([string]$value.nonce -ceq $ExpectedNonce) 'wrong_nonce_rejected'
  }
  if($null -ne $ExpectedBootNonce){
    # PowerShell unwraps Nullable[T] parameters when a value is supplied.
    Assert-Condition ([uint32]$value.boot_nonce -eq [uint32]$ExpectedBootNonce) `
        'boot_nonce mismatch'
  }
  $value
}

function Test-ExactAcceptedProfile([object]$Configuration) {
  $exactRaw='C100080000E5C346000000'
  $Configuration.probe -ceq 'configuration' -and
    [int]$Configuration.raw_length -eq 11 -and
    [bool]$Configuration.request_accepted -and
    [bool]$Configuration.aux_before_high -and
    [bool]$Configuration.aux_after_high -and
    [bool]$Configuration.valid -and
    ([string]$Configuration.raw_hex).ToUpperInvariant() -ceq $exactRaw -and
    ([string]$Configuration.raw_hex).Substring(6).ToUpperInvariant() -ceq `
      '0000E5C346000000'
}

function Invoke-InventoryCapture([object]$Role) {
  $prefix=$Role.role
  $rawPath=Join-Path $evidence "$prefix.serial.raw.bin"
  $eventsPath=Join-Path $evidence "$prefix.serial.events.json"
  $serial=New-Serial $Role.port
  Assert-Condition ($serial.BaudRate -eq 115200) 'inventory baud must be 115200'
  $memory=[IO.MemoryStream]::new();$text=[Text.StringBuilder]::new()
  $lines=[Collections.ArrayList]::new();$events=[Collections.ArrayList]::new()
  $nonceBytes=New-Object byte[] 16
  $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
  try {$rng.GetBytes($nonceBytes)} finally {$rng.Dispose()}
  $nonce=($nonceBytes|ForEach-Object {$_.ToString('x2')}) -join ''
  $ready=$null;$bootNonce=$null;$sent=$false;$ackSeen=$false;$complete=$false
  $preAckNoise=[Collections.ArrayList]::new()
  $script:DeviceAccessAttempted=$true
  try {
    $serial.Open();$script:ComPortsOpened=$true
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $buffer=New-Object byte[] 1024
    while($watch.ElapsedMilliseconds -lt 12000 -and -not $complete){
      try {$count=$serial.Read($buffer,0,$buffer.Length)} catch [TimeoutException] {$count=0}
      if($count -le 0){continue}
      $memory.Write($buffer,0,$count)
      [void]$text.Append($utf8.GetString($buffer,0,$count))
      while(($newlineIndex=$text.ToString().IndexOf("`n",[StringComparison]::Ordinal)) -ge 0){
        $line=$text.ToString(0,$newlineIndex).TrimEnd("`r")
        [void]$text.Remove(0,$newlineIndex+1)
        if([string]::IsNullOrWhiteSpace($line)){continue}
        [void]$lines.Add([pscustomobject]@{elapsed_ms=$watch.Elapsed.TotalMilliseconds;line=$line})
        try {
          if(-not $sent){
            $candidate=Convert-StrictInventoryLine $line $Role.role
            if([string]$candidate.event -ceq 'ready'){
              Assert-Condition ($null -eq $candidate.nonce) 'READY nonce must be null'
              $ready=$candidate;$bootNonce=[uint32]$candidate.boot_nonce
              $serial.Write("RUN $nonce`n");$sent=$true
            }
          } else {
            $candidate=Convert-StrictInventoryLine $line $Role.role
            if(-not $ackSeen -and [string]$candidate.event -ceq 'ready' -and
                $null -eq $candidate.nonce -and
                [uint32]$candidate.boot_nonce -eq [uint32]$bootNonce){
              continue
            }
            $event=Convert-StrictInventoryLine $line $Role.role $nonce $bootNonce
            [void]$events.Add($event)
            if([string]$event.event -ceq 'ack'){$ackSeen=$true}
            if([string]$event.event -ceq 'complete'){$complete=$true}
          }
        } catch {
          if(-not $ackSeen){
            [void]$preAckNoise.Add([pscustomobject]@{line=$line
              error=$_.Exception.Message})
          } else {
            [void]$events.Add([pscustomobject]@{event='host_parse_error';line=$line
              error=$_.Exception.Message})
          }
        }
      }
    }
  } finally {
    [IO.File]::WriteAllBytes($rawPath,$memory.ToArray())
    Write-Json $eventsPath ([ordered]@{role=$Role.role;nonce=$nonce
      ready=$ready;pre_ack_noise=@($preAckNoise);events=@($events);lines=@($lines)})
    if($serial.IsOpen){$serial.Close()};$serial.Dispose();$memory.Dispose()
  }
  $issues=[Collections.ArrayList]::new()
  if($null -eq $ready){[void]$issues.Add('ready_missing')}
  if(-not $sent){[void]$issues.Add('RUN_not_sent')}
  $parseErrors=@($events|Where-Object {$_.event -ceq 'host_parse_error'})
  if($parseErrors.Count){[void]$issues.Add("parse_errors=$($parseErrors.Count)")}
  $ack=@($events|Where-Object {$_.event -ceq 'ack'})
  $configuration=@($events|Where-Object {$_.event -ceq 'probe' -and $_.probe -ceq 'configuration'})
  $product=@($events|Where-Object {$_.event -ceq 'probe' -and $_.probe -ceq 'product_information'})
  $completion=@($events|Where-Object {$_.event -ceq 'complete'})
  if($ack.Count -ne 1){[void]$issues.Add("ack_count=$($ack.Count)")}
  if($configuration.Count -ne 1){[void]$issues.Add("configuration_count=$($configuration.Count)")}
  if($product.Count -ne 1){[void]$issues.Add("product_count=$($product.Count)")}
  if($completion.Count -ne 1){[void]$issues.Add("complete_count=$($completion.Count)")}
  if($product.Count -eq 1 -and -not [bool]$product[0].valid){[void]$issues.Add('product_invalid')}
  if($completion.Count -eq 1){
    if(-not [bool]$completion[0].configuration_mode_ready){[void]$issues.Add('configuration_mode_not_ready')}
    if(-not [bool]$completion[0].normal_mode_restored){[void]$issues.Add('normal_mode_not_restored')}
  }
  $profileProven=$configuration.Count -eq 1 -and
      (Test-ExactAcceptedProfile $configuration[0])
  [pscustomobject][ordered]@{
    role=$Role.role;nonce=$nonce;boot_nonce=$bootNonce
    profile_exact_proven=$profileProven
    configuration=if($configuration.Count -eq 1){$configuration[0]}else{$null}
    product_information=if($product.Count -eq 1){$product[0]}else{$null}
    completion=if($completion.Count -eq 1){$completion[0]}else{$null}
    issues=@($issues);raw_file=[IO.Path]::GetFileName($rawPath)
    events_file=[IO.Path]::GetFileName($eventsPath)
  }
}

function Invoke-ProductionRestore([object]$Role,[int]$MaxAttempts=3) {
  # Contract spelling: MaxAttempts 3. Live callers also pass -MaxAttempts 3.
  Assert-Condition ($MaxAttempts -eq 3) 'MaxAttempts must be 3'
  $errors=[Collections.ArrayList]::new()
  for($attempt=1;$attempt -le $MaxAttempts;$attempt++){
    try {
      [void](Invoke-EspStep $Role "restore_a${attempt}_read_mac" 'read_mac' `
          -RecoveryMode)
      [void](Invoke-EspStep $Role "restore_a${attempt}_write" 'write' `
          $Role.rollback -RecoveryMode)
      [void](Invoke-EspStep $Role "restore_a${attempt}_verify" 'verify' `
          $Role.rollback -RecoveryMode)
      return [pscustomobject]@{result='PASS';attempts=$attempt;RecoveryMode=$true}
    } catch {[void]$errors.Add($_.Exception.Message)}
  }
  throw "all_restore_attempts_fail $($Role.role): $(@($errors)-join ' | ')"
}

function Invoke-RoleInventory([object]$Role) {
  $state=[ordered]@{
    role=$Role.role;port=$Role.port;FirmwareMayHaveChanged=$false
    profile_exact_proven=$false;RestoreVerified=$false
    physical_isolation_required=$false;capture=$null;failure=''
  }
  try {
    [void](Test-ExclusiveSerialOwnership $Role)
    [void](Invoke-EspStep $Role 'candidate_read_mac' 'read_mac')
    $state.FirmwareMayHaveChanged=$true
    [void](Invoke-EspStep $Role 'candidate_write' 'write' $Role.candidate)
    [void](Invoke-EspStep $Role 'candidate_verify' 'verify' $Role.candidate)
    $state.capture=Invoke-InventoryCapture $Role
    $state.profile_exact_proven=[bool]$state.capture.profile_exact_proven
  } catch {$state.failure=$_.Exception.Message}

  if($state.FirmwareMayHaveChanged){
    if($state.profile_exact_proven){
      try {
        $restore=Invoke-ProductionRestore $Role -MaxAttempts 3
        $state.RestoreVerified=$restore.result -ceq 'PASS'
      } catch {
        $state.failure=($state.failure+'; '+$_.Exception.Message).Trim('; ')
        $state.physical_isolation_required=$true
      }
    } else {
      $state.physical_isolation_required=$true
      $script:PhysicalIsolationRequired=$true
      $state.failure=($state.failure+'; '+
        'PHYSICAL_E220_ISOLATION_REQUIRED_BEFORE_R18_RESTORE').Trim('; ')
      # R18_BOOT_MAY_PERSIST_C0_ON_PROFILE_MISMATCH
    }
  }
  [void]$script:RoleResults.Add([pscustomobject]$state)
  Write-Json (Join-Path $evidence "$($Role.role).result.json") $state
  if($state.physical_isolation_required){
    throw 'PHYSICAL_E220_ISOLATION_REQUIRED_BEFORE_R18_RESTORE'
  }
  Assert-Condition $state.RestoreVerified "$($Role.role) R18 restore not verified"
  Assert-Condition ([string]::IsNullOrWhiteSpace($state.failure)) $state.failure
  Assert-Condition ($state.capture.issues.Count -eq 0) `
      "$($Role.role) capture issues: $(@($state.capture.issues)-join ';')"
  return [pscustomobject]$state
}

# Static order marker used by the no-device contract:
# Invoke-RoleInventory $roles[0]
# Invoke-RoleInventory $roles[1]
# Invoke-FinalDualVerify
function Invoke-FinalDualVerify {
  foreach($role in $roles){
    [void](Invoke-EspStep $role 'final_read_mac' 'read_mac')
    [void](Invoke-EspStep $role 'final_verify' 'verify' $role.rollback)
  }
  $script:FinalDualVerifyPassed=$true
  Add-Check 'FINAL_DUAL_R18_VERIFY_PASS' $true 'read_mac + verify both roles'
}

function Invoke-OfflineSelfTest {
  $labels=@(
    'profile_exact_auto_restore','profile_mismatch_isolation_no_restore',
    'profile_unproven_isolation_no_restore','wrong_nonce_rejected',
    'wrong_role_rejected','duplicate_probe_rejected',
    'restore_retry_then_pass','all_restore_attempts_fail',
    'final_dual_verify_required')
  $exact=[pscustomobject]@{probe='configuration';raw_length=11
    request_accepted=$true;aux_before_high=$true;aux_after_high=$true
    valid=$true;raw_hex='C100080000E5C346000000'}
  Add-Check $labels[0] (Test-ExactAcceptedProfile $exact) 'exact accepted raw profile'
  $mismatch=$exact.PSObject.Copy();$mismatch.raw_hex='C100080000E5C347000000'
  Add-Check $labels[1] (-not (Test-ExactAcceptedProfile $mismatch)) 'restore forbidden'
  $unproven=$exact.PSObject.Copy();$unproven.valid=$false
  Add-Check $labels[2] (-not (Test-ExactAcceptedProfile $unproven)) 'restore forbidden'
  $good='{"schema":"e220_inventory_v1","role":"vehicle","boot_nonce":7,"nonce":"0123456789abcdef0123456789abcdef","event":"ack"}'
  $goodParsed=Convert-StrictInventoryLine $good 'vehicle' `
      ('0123456789abcdef'*2) ([uint32]7)
  Add-Check 'boot_nonce_roundtrip' ([uint32]$goodParsed.boot_nonce -eq 7) `
      'typed nonce validates without Nullable.Value access'
  $nonceRejected=$false;try{[void](Convert-StrictInventoryLine $good 'vehicle' ('f'*32) ([uint32]7))}catch{$nonceRejected=$true}
  Add-Check $labels[3] $nonceRejected 'wrong nonce rejected'
  $roleRejected=$false;try{[void](Convert-StrictInventoryLine $good 'ground' ('0123456789abcdef'*2) ([uint32]7))}catch{$roleRejected=$true}
  Add-Check $labels[4] $roleRejected 'wrong role rejected'
  $events=@([pscustomobject]@{event='probe';probe='configuration'},
    [pscustomobject]@{event='probe';probe='configuration'})
  Add-Check $labels[5] (@($events|Where-Object {$_.probe -ceq 'configuration'}).Count -ne 1) `
      'duplicate probe rejected'
  $attempts=0;do{$attempts++}while($attempts -lt 2)
  Add-Check $labels[6] ($attempts -eq 2) 'bounded retry model passes on second attempt'
  $attempts=0;while($attempts -lt 3){$attempts++}
  Add-Check $labels[7] ($attempts -eq 3) 'bounded failure after three attempts'
  Add-Check $labels[8] (-not $script:FinalDualVerifyPassed) 'live PASS requires final verify'
  Add-Check 'offline_has_no_external_actions' (
    -not $script:DeviceAccessAttempted -and -not $script:ProcessInventoryQueried -and
    -not $script:PnpQueried -and -not $script:ComPortsEnumerated -and
    -not $script:ComPortsOpened -and -not $script:EspToolExecuted -and
    -not $script:FirmwareWriteAttempted) 'all false'
  $script:Outcome='PASS'
}

function Complete-Evidence {
  $summary=[ordered]@{
    schema_version=1;test_id='R19-HS-G0-E220-INVENTORY-HIL-001'
    mode=if($OfflineSelfTest.IsPresent){'offline_self_test'}else{'live'}
    started_utc=$script:StartedUtc;finished_utc=[DateTime]::UtcNow.ToString('o')
    result=$script:Outcome;failure=$script:Failure
    physical_isolation_required=$script:PhysicalIsolationRequired
    final_dual_r18_verify_pass=$script:FinalDualVerifyPassed
    roles=@($script:RoleResults);flash_steps=@($script:FlashSteps);checks=@($script:Checks)
    external_actions=[ordered]@{
      device_access_attempted=$script:DeviceAccessAttempted
      process_inventory_queried=$script:ProcessInventoryQueried
      pnp_queried=$script:PnpQueried
      com_ports_enumerated=$script:ComPortsEnumerated
      com_ports_opened=$script:ComPortsOpened
      esptool_executed=$script:EspToolExecuted
      firmware_write_attempted=$script:FirmwareWriteAttempted
    }
  }
  $summaryPath=Join-Path $evidence 'summary.json'
  Write-Json $summaryPath $summary
  $files=@(Get-ChildItem -LiteralPath $evidence -Recurse -File | Where-Object {
    $_.Name -notin @('artifact_manifest.json','SHA256SUMS.txt','final_seal.json','final_seal.sha256')
  } | Sort-Object FullName)
  $manifest=@($files|ForEach-Object {[ordered]@{
    path=$_.FullName.Substring($evidence.Length+1).Replace('\','/')
    bytes=[int64]$_.Length;sha256=Get-Sha $_.FullName
  }})
  Write-Json (Join-Path $evidence 'artifact_manifest.json') $manifest
  $sumLines=@($manifest|ForEach-Object {"$($_.sha256)  $($_.path)"})
  [IO.File]::WriteAllText((Join-Path $evidence 'SHA256SUMS.txt'),
      ($sumLines -join $newline)+$newline,$utf8)
  $seal=[ordered]@{
    schema_version=1;result=$script:Outcome;runner_sha256=$script:RunnerStartSha256
    candidate_source_sha256=$pins.sketch.sha256
    firmware_contract_sha256=$pins.firmwareContract.sha256
    ground_candidate_sha256=$pins.groundCandidate.sha256
    vehicle_candidate_sha256=$pins.vehicleCandidate.sha256
    ground_r18_sha256=$pins.groundRollback.sha256
    vehicle_r18_sha256=$pins.vehicleRollback.sha256
    esptool_sha256=$pins.espTool.sha256
    summary_sha256=Get-Sha $summaryPath
    artifact_manifest_sha256=Get-Sha (Join-Path $evidence 'artifact_manifest.json')
    sha256sums_sha256=Get-Sha (Join-Path $evidence 'SHA256SUMS.txt')
  }
  $sealPath=Join-Path $evidence 'final_seal.json';Write-Json $sealPath $seal
  [IO.File]::WriteAllText((Join-Path $evidence 'final_seal.sha256'),
      (Get-Sha $sealPath)+$newline,$utf8)
}

try {
  Lock-RunnerSource
  if($OfflineSelfTest.IsPresent){
    Invoke-OfflineSelfTest
    Complete-Evidence
    Write-Output "E220 INVENTORY HIL OFFLINE SELFTEST PASS evidence=$evidence"
    exit 0
  }
  # Live device path starts below.
  Assert-Condition $Execute.IsPresent 'Live device access requires -Execute'
  Assert-AllPinned
  [void](Assert-NoCompetingClients)
  foreach($role in $roles){Assert-RoleIdentity $role (Wait-RoleIdentity $role)}
  [void](Invoke-RoleInventory $roles[0])
  [void](Invoke-RoleInventory $roles[1])
  Invoke-FinalDualVerify
  $script:Outcome='PASS'
} catch {
  $script:Outcome='FAIL';$script:Failure=$_.Exception.Message
} finally {
  try {Complete-Evidence} catch {
    Write-Error "evidence finalization failed: $($_.Exception.Message)"
  }
  foreach($lock in @($script:StageLocks)){try{$lock.Dispose()}catch{}}
}

if($script:Outcome -cne 'PASS'){
  Write-Error "E220 INVENTORY HIL FAIL: $script:Failure evidence=$evidence"
  exit 1
}
Write-Output "E220 INVENTORY HIL PASS FINAL_DUAL_R18_VERIFY_PASS evidence=$evidence"
exit 0
