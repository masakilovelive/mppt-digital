[CmdletBinding()]
param(
  [ValidatePattern('^COM[0-9]+$')]
  [string]$VehiclePort = 'COM3',

  [string]$VehiclePnpDeviceId =
      'USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000',

  [ValidatePattern('^COM[0-9]+$')]
  [string]$GroundPort = 'COM6',

  [string]$GroundPnpDeviceId =
      'USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000',

  [string]$OutputDirectory = '',

  [ValidateRange(1, 86400)]
  [int]$DurationSeconds = 7200,

  [ValidateRange(100, 60000)]
  [int]$PollIntervalMs = 250,

  [ValidateRange(1000, 60000)]
  [int]$CheckpointIntervalMs = 10000,

  [string]$StopSignalPath = '',

  [ValidateRange(0, 2147483647)]
  [int]$WatchProcessId = 0,

  [switch]$SelfTest,
  [string]$SelfTestEvidenceDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HardwareQueryCount = [long]0
$script:NativeIdentityQueryCount = [long]0
$script:RegistryQueryCount = [long]0
$script:SerialPortOpenCount = [long]0
$script:PowerCfgInvocationCount = [long]0
$script:UsbPowerSubgroupGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:UsbSelectiveSuspendGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$script:Usb3LinkPowerManagementGuid =
    'd4e98f31-5ffe-4ce1-be31-1b38b384c009'

function Write-BytesDurableCreateNew {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
  )
  $stream = New-Object System.IO.FileStream(
      $Path,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::Read,
      4096,
      [System.IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) {
      $stream.Write($Bytes, 0, $Bytes.Length)
    }
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-JsonDurableCreateNew {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value,
    [ValidateRange(2, 100)][int]$Depth = 30
  )
  [string]$json = $Value | ConvertTo-Json -Depth $Depth
  [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
      $json + [Environment]::NewLine)
  Write-BytesDurableCreateNew -Path $Path -Bytes $bytes
}

function New-DurableJsonlStream {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (New-Object System.IO.FileStream(
      $Path,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::Read,
      4096,
      [System.IO.FileOptions]::WriteThrough))
}

function Write-DurableJsonlRecord {
  param(
    [Parameter(Mandatory = $true)]$Stream,
    [Parameter(Mandatory = $true)]$Value
  )
  [string]$json = $Value | ConvertTo-Json -Depth 30 -Compress
  [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
      $json + "`n")
  $Stream.Write($bytes, 0, $Bytes.Length)
  $Stream.Flush($true)
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [string](Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-TextSha256 {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
  $provider = [System.Security.Cryptography.SHA256]::Create()
  try {
    [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    return [string](($provider.ComputeHash($bytes) | ForEach-Object {
          $_.ToString('x2') }) -join '').ToUpperInvariant()
  } finally {
    $provider.Dispose()
  }
}

function Invoke-ReadOnlyPowerCfg {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  ++$script:PowerCfgInvocationCount
  $start = New-Object System.Diagnostics.ProcessStartInfo
  $start.FileName = 'powercfg.exe'
  $start.Arguments = $Arguments -join ' '
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $start
  try {
    if (-not $process.Start()) {
      throw 'powercfg.exe process did not start.'
    }
    [string]$stdout = $process.StandardOutput.ReadToEnd()
    [string]$stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject][ordered]@{
      command=('powercfg.exe ' + ($Arguments -join ' '))
      exit_code=[int]$process.ExitCode
      stdout=$stdout
      stderr=$stderr
      stdout_sha256=Get-TextSha256 -Text $stdout
      stderr_sha256=Get-TextSha256 -Text $stderr
    }
  } finally {
    $process.Dispose()
  }
}

function ConvertTo-PowerCfgEvidence {
  param([Parameter(Mandatory = $true)]$Query)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  return [pscustomobject][ordered]@{
    command=[string]$Query.command
    exit_code=[int]$Query.exit_code
    stdout_utf8_base64=[Convert]::ToBase64String(
        $encoding.GetBytes([string]$Query.stdout))
    stderr_utf8_base64=[Convert]::ToBase64String(
        $encoding.GetBytes([string]$Query.stderr))
    stdout_sha256=[string]$Query.stdout_sha256
    stderr_sha256=[string]$Query.stderr_sha256
  }
}

function ConvertFrom-PowerSettingQuery {
  param(
    [Parameter(Mandatory = $true)]$Query,
    [Parameter(Mandatory = $true)][string]$SettingGuid,
    [Parameter(Mandatory = $true)][hashtable]$Interpretations
  )
  $matches = @([regex]::Matches([string]$Query.stdout,
      '(?i)0x([0-9a-f]{8})'))
  [bool]$available = ([int]$Query.exit_code -eq 0 -and
      $matches.Count -eq 2)
  [Nullable[uint32]]$acIndex = $null
  [Nullable[uint32]]$dcIndex = $null
  [string]$acHex = ''
  [string]$dcHex = ''
  if ($available) {
    $acHex = '0x' + $matches[0].Groups[1].Value.ToUpperInvariant()
    $dcHex = '0x' + $matches[1].Groups[1].Value.ToUpperInvariant()
    $acIndex = [Convert]::ToUInt32($matches[0].Groups[1].Value, 16)
    $dcIndex = [Convert]::ToUInt32($matches[1].Groups[1].Value, 16)
  }
  [string]$acMeaning = if ($null -ne $acIndex -and
      $Interpretations.ContainsKey([uint32]$acIndex)) {
    [string]$Interpretations[[uint32]$acIndex]
  } else { 'unknown' }
  [string]$dcMeaning = if ($null -ne $dcIndex -and
      $Interpretations.ContainsKey([uint32]$dcIndex)) {
    [string]$Interpretations[[uint32]$dcIndex]
  } else { 'unknown' }
  return [pscustomobject][ordered]@{
    setting_guid=$SettingGuid
    subgroup_guid=$script:UsbPowerSubgroupGuid
    available=$available
    ac_index_hex=$acHex
    ac_index_uint32=if ($null -ne $acIndex) {[uint32]$acIndex} else {$null}
    ac_interpretation=$acMeaning
    dc_index_hex=$dcHex
    dc_index_uint32=if ($null -ne $dcIndex) {[uint32]$dcIndex} else {$null}
    dc_interpretation=$dcMeaning
    query=ConvertTo-PowerCfgEvidence -Query $Query
  }
}

function Get-StartupPowerMetadata {
  $active = Invoke-ReadOnlyPowerCfg -Arguments @('/GETACTIVESCHEME')
  $guidMatch = [regex]::Match([string]$active.stdout,
      '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
  [string]$schemeGuid = if ($guidMatch.Success) {
    $guidMatch.Groups[1].Value.ToLowerInvariant()
  } else { '' }
  $selective = [pscustomobject][ordered]@{
    setting_guid=$script:UsbSelectiveSuspendGuid
    subgroup_guid=$script:UsbPowerSubgroupGuid
    available=$false;ac_index_hex='';ac_index_uint32=$null
    ac_interpretation='unknown';dc_index_hex='';dc_index_uint32=$null
    dc_interpretation='unknown';query=$null
  }
  $link = [pscustomobject][ordered]@{
    setting_guid=$script:Usb3LinkPowerManagementGuid
    subgroup_guid=$script:UsbPowerSubgroupGuid
    available=$false;ac_index_hex='';ac_index_uint32=$null
    ac_interpretation='unknown';dc_index_hex='';dc_index_uint32=$null
    dc_interpretation='unknown';query=$null
  }
  if ($active.exit_code -eq 0 -and $schemeGuid.Length -eq 36) {
    $selectiveQuery = Invoke-ReadOnlyPowerCfg -Arguments @(
        '/QH', $schemeGuid, $script:UsbPowerSubgroupGuid,
        $script:UsbSelectiveSuspendGuid)
    $linkQuery = Invoke-ReadOnlyPowerCfg -Arguments @(
        '/QH', $schemeGuid, $script:UsbPowerSubgroupGuid,
        $script:Usb3LinkPowerManagementGuid)
    $selective = ConvertFrom-PowerSettingQuery -Query $selectiveQuery `
        -SettingGuid $script:UsbSelectiveSuspendGuid `
        -Interpretations @{
          ([uint32]0)='disabled';([uint32]1)='enabled'
        }
    $link = ConvertFrom-PowerSettingQuery -Query $linkQuery `
        -SettingGuid $script:Usb3LinkPowerManagementGuid `
        -Interpretations @{
          ([uint32]0)='off';([uint32]1)='minimum_power_savings'
          ([uint32]2)='moderate_power_savings'
          ([uint32]3)='maximum_power_savings'
        }
  }
  return [pscustomobject][ordered]@{
    schema_version=1
    captured_utc=[DateTime]::UtcNow.ToString('o')
    immutable_after_start=$true
    modeled_offline=$false
    monitor_source_sha256=Get-FileSha256 -Path $PSCommandPath
    collection_method='powercfg.exe read-only /GETACTIVESCHEME and /QH'
    commands_read_only=$true
    powercfg_invocation_count=[long]$script:PowerCfgInvocationCount
    active_power_scheme=[pscustomobject][ordered]@{
      available=($active.exit_code -eq 0 -and $schemeGuid.Length -eq 36)
      guid=$schemeGuid
      query=ConvertTo-PowerCfgEvidence -Query $active
    }
    usb_selective_suspend=$selective
    usb3_link_power_management=$link
  }
}

function New-ModeledStartupPowerMetadata {
  return [pscustomobject][ordered]@{
    schema_version=1
    captured_utc='2030-01-01T00:00:00.0000000Z'
    immutable_after_start=$true
    modeled_offline=$true
    monitor_source_sha256=Get-FileSha256 -Path $PSCommandPath
    collection_method='modeled disk-only fixture; no process launched'
    commands_read_only=$true
    powercfg_invocation_count=0
    active_power_scheme=[pscustomobject][ordered]@{
      available=$true
      guid='381b4222-f694-41f0-9685-ff5bb260df2e'
      query=$null
    }
    usb_selective_suspend=[pscustomobject][ordered]@{
      setting_guid=$script:UsbSelectiveSuspendGuid
      subgroup_guid=$script:UsbPowerSubgroupGuid
      available=$true
      ac_index_hex='0x00000001';ac_index_uint32=[uint32]1
      ac_interpretation='enabled'
      dc_index_hex='0x00000001';dc_index_uint32=[uint32]1
      dc_interpretation='enabled';query=$null
    }
    usb3_link_power_management=[pscustomobject][ordered]@{
      setting_guid=$script:Usb3LinkPowerManagementGuid
      subgroup_guid=$script:UsbPowerSubgroupGuid
      available=$true
      ac_index_hex='0x00000002';ac_index_uint32=[uint32]2
      ac_interpretation='moderate_power_savings'
      dc_index_hex='0x00000002';dc_index_uint32=[uint32]2
      dc_interpretation='moderate_power_savings';query=$null
    }
  }
}

function Initialize-NativeDeviceProbeType {
  if ('VcUsbContinuity.NativeDeviceProbe' -as [type]) { return }
  $definition = @'
using System;
using System.Runtime.InteropServices;

namespace VcUsbContinuity {
  [StructLayout(LayoutKind.Sequential)]
  internal struct DEVPROPKEY {
    internal Guid fmtid;
    internal uint pid;
    internal DEVPROPKEY(Guid formatId, uint propertyId) {
      fmtid = formatId;
      pid = propertyId;
    }
  }

  public sealed class DeviceProbeResult {
    public string DeviceInstanceId { get; internal set; }
    public uint LocateConfigRet { get; internal set; }
    public bool Present { get; internal set; }
    public uint StatusConfigRet { get; internal set; }
    public uint DevNodeStatus { get; internal set; }
    public uint ProblemCode { get; internal set; }
    public bool Started { get; internal set; }
    public bool HasProblem { get; internal set; }
    public uint LastArrivalConfigRet { get; internal set; }
    public long? LastArrivalFileTimeUtc { get; internal set; }
    public string LastArrivalUtc { get; internal set; }
  }

  public static class NativeDeviceProbe {
    private const uint CR_SUCCESS = 0;
    private const uint DN_STARTED = 0x00000008;
    private const uint DN_HAS_PROBLEM = 0x00000400;
    // DEVPKEY_Device_LastArrivalDate is PID 102 (0x66) in this property set.
    private const uint DEVPKEY_Device_LastArrivalDate_PID = 102;
    private static readonly Guid DevicePropertySet =
        new Guid("83da6326-97a6-4088-9453-a1923f573b29");

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    private static extern uint CM_Locate_DevNodeW(
        out uint deviceInstance, string deviceInstanceId, uint flags);

    [DllImport("cfgmgr32.dll")]
    private static extern uint CM_Get_DevNode_Status(
        out uint status, out uint problemNumber,
        uint deviceInstance, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    private static extern uint CM_Get_DevNode_PropertyW(
        uint deviceInstance, ref DEVPROPKEY propertyKey,
        out uint propertyType, byte[] propertyBuffer,
        ref uint propertyBufferSize, uint flags);

    public static DeviceProbeResult Query(string exactDeviceInstanceId) {
      if (String.IsNullOrEmpty(exactDeviceInstanceId)) {
        throw new ArgumentException("An exact device instance ID is required.",
            "exactDeviceInstanceId");
      }
      DeviceProbeResult result = new DeviceProbeResult();
      result.DeviceInstanceId = exactDeviceInstanceId;
      result.StatusConfigRet = UInt32.MaxValue;
      result.LastArrivalConfigRet = UInt32.MaxValue;
      result.LastArrivalUtc = String.Empty;

      uint deviceInstance;
      result.LocateConfigRet = CM_Locate_DevNodeW(
          out deviceInstance, exactDeviceInstanceId, 0);
      result.Present = result.LocateConfigRet == CR_SUCCESS;
      if (!result.Present) return result;

      uint status;
      uint problem;
      result.StatusConfigRet = CM_Get_DevNode_Status(
          out status, out problem, deviceInstance, 0);
      if (result.StatusConfigRet == CR_SUCCESS) {
        result.DevNodeStatus = status;
        result.ProblemCode = problem;
        result.Started = (status & DN_STARTED) != 0;
        result.HasProblem = (status & DN_HAS_PROBLEM) != 0 || problem != 0;
      }

      DEVPROPKEY lastArrivalKey = new DEVPROPKEY(
          DevicePropertySet, DEVPKEY_Device_LastArrivalDate_PID);
      byte[] buffer = new byte[8];
      uint bufferSize = (uint)buffer.Length;
      uint propertyType;
      result.LastArrivalConfigRet = CM_Get_DevNode_PropertyW(
          deviceInstance, ref lastArrivalKey, out propertyType,
          buffer, ref bufferSize, 0);
      if (result.LastArrivalConfigRet == CR_SUCCESS && bufferSize == 8) {
        long fileTime = BitConverter.ToInt64(buffer, 0);
        if (fileTime > 0) {
          result.LastArrivalFileTimeUtc = fileTime;
          result.LastArrivalUtc = DateTime.FromFileTimeUtc(fileTime).ToString("o");
        }
      }
      return result;
    }
  }
}
'@
  Add-Type -TypeDefinition $definition -Language CSharp
}

function Get-ExactAssignedPort {
  param([Parameter(Mandatory = $true)][string]$PnpDeviceId)
  ++$script:RegistryQueryCount
  $key = $null
  try {
    [string]$path = 'SYSTEM\CurrentControlSet\Enum\' + $PnpDeviceId +
        '\Device Parameters'
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path, $false)
    if ($null -eq $key) {
      return [pscustomobject]@{ value='';error='registry_key_missing' }
    }
    [object]$value = $key.GetValue('PortName', $null)
    return [pscustomobject]@{
      value=if ($null -ne $value) {[string]$value} else {''}
      error=if ($null -ne $value) {''} else {'PortName_value_missing'}
    }
  } catch {
    return [pscustomobject]@{ value='';error=$_.Exception.Message }
  } finally {
    if ($null -ne $key) { $key.Dispose() }
  }
}

function Get-LiveSerialMap {
  ++$script:RegistryQueryCount
  $key = $null
  try {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'HARDWARE\DEVICEMAP\SERIALCOMM', $false)
    if ($null -eq $key) {
      return [pscustomobject][ordered]@{
        values=@();entries=@();query_error='registry_key_missing'
      }
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @($key.GetValueNames() | Sort-Object)) {
      $entries.Add([pscustomobject][ordered]@{
        mapping_name=[string]$name
        port=[string]$key.GetValue($name, '')
      })
    }
    [string[]]$values = @($entries.ToArray() | ForEach-Object {
          [string]$_.port } | Sort-Object)
    return [pscustomobject][ordered]@{
      values=$values;entries=$entries.ToArray();query_error=''
    }
  } catch {
    return [pscustomobject][ordered]@{
      values=@();entries=@();query_error=$_.Exception.Message
    }
  } finally {
    if ($null -ne $key) { $key.Dispose() }
  }
}

function Get-LiveRoleSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Role,
    [Parameter(Mandatory = $true)][string]$ExpectedPort,
    [Parameter(Mandatory = $true)][string]$PnpDeviceId,
    [Parameter(Mandatory = $true)]$SerialMap
  )
  ++$script:NativeIdentityQueryCount
  $probe = $null
  [string]$probeError = ''
  try {
    $probe = [VcUsbContinuity.NativeDeviceProbe]::Query($PnpDeviceId)
  } catch {
    $probeError = $_.Exception.Message
  }
  $assignment = Get-ExactAssignedPort -PnpDeviceId $PnpDeviceId
  [int]$mapCount = @($SerialMap.values | Where-Object {
        [string]::Equals([string]$_, $ExpectedPort,
            [StringComparison]::OrdinalIgnoreCase) }).Count
  [string]$assignedPort = [string]$assignment.value
  return [pscustomobject][ordered]@{
    role=$Role
    pnp_device_id=$PnpDeviceId
    expected_port=$ExpectedPort
    present=($null -ne $probe -and [bool]$probe.Present)
    locate_configret=if ($null -ne $probe) {
      [uint32]$probe.LocateConfigRet
    } else { $null }
    status_configret=if ($null -ne $probe) {
      [uint32]$probe.StatusConfigRet
    } else { $null }
    devnode_status=if ($null -ne $probe) {
      [uint32]$probe.DevNodeStatus
    } else { $null }
    started=($null -ne $probe -and [bool]$probe.Started)
    has_problem=($null -ne $probe -and [bool]$probe.HasProblem)
    problem_code=if ($null -ne $probe) {
      [uint32]$probe.ProblemCode
    } else { $null }
    last_arrival_configret=if ($null -ne $probe) {
      [uint32]$probe.LastArrivalConfigRet
    } else { $null }
    last_arrival_filetime_utc=if ($null -ne $probe) {
      $probe.LastArrivalFileTimeUtc
    } else { $null }
    last_arrival_utc=if ($null -ne $probe) {
      [string]$probe.LastArrivalUtc
    } else { '' }
    assigned_port=$assignedPort
    assigned_port_exact=[string]::Equals($assignedPort, $ExpectedPort,
        [StringComparison]::OrdinalIgnoreCase)
    serial_map_match_count=$mapCount
    query_error=(@($probeError, [string]$assignment.error) |
        Where-Object { -not [string]::IsNullOrEmpty($_) }) -join '; '
  }
}

function Get-LiveContinuitySnapshot {
  ++$script:HardwareQueryCount
  $serialMap = Get-LiveSerialMap
  $vehicle = Get-LiveRoleSnapshot -Role 'vehicle' `
      -ExpectedPort $VehiclePort -PnpDeviceId $VehiclePnpDeviceId `
      -SerialMap $serialMap
  $ground = Get-LiveRoleSnapshot -Role 'ground' `
      -ExpectedPort $GroundPort -PnpDeviceId $GroundPnpDeviceId `
      -SerialMap $serialMap
  return [pscustomobject][ordered]@{
    roles=[pscustomobject][ordered]@{
      vehicle=$vehicle
      ground=$ground
    }
    serial_map=[pscustomobject][ordered]@{
      values=$serialMap.values
      entries=$serialMap.entries
      query_error=[string]$serialMap.query_error
    }
  }
}

function ConvertTo-ComparableText {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return '<null>' }
  if ($Value -is [Array]) {
    return [string]($Value | ConvertTo-Json -Compress)
  }
  return [string]$Value
}

function Compare-ContinuitySnapshots {
  param([Parameter(Mandatory = $true)]$Previous,
        [Parameter(Mandatory = $true)]$Current)
  $changes = New-Object 'System.Collections.Generic.List[string]'
  [string[]]$fields = @(
    'present','locate_configret','status_configret','devnode_status',
    'started','has_problem','problem_code','last_arrival_configret',
    'last_arrival_filetime_utc','assigned_port','assigned_port_exact',
    'serial_map_match_count','query_error')
  foreach ($role in @('vehicle','ground')) {
    $before = $Previous.roles.$role
    $after = $Current.roles.$role
    foreach ($field in $fields) {
      [string]$oldValue = ConvertTo-ComparableText -Value $before.$field
      [string]$newValue = ConvertTo-ComparableText -Value $after.$field
      if ($oldValue -cne $newValue) {
        $changes.Add(('{0}.{1}:{2}->{3}' -f $role, $field,
            $oldValue, $newValue))
      }
    }
  }
  [string]$oldMap = ConvertTo-ComparableText -Value $Previous.serial_map.values
  [string]$newMap = ConvertTo-ComparableText -Value $Current.serial_map.values
  if ($oldMap -cne $newMap) {
    $changes.Add(('serial_map.values:{0}->{1}' -f $oldMap, $newMap))
  }
  if ([string]$Previous.serial_map.query_error -cne
      [string]$Current.serial_map.query_error) {
    $changes.Add(('serial_map.query_error:{0}->{1}' -f
        [string]$Previous.serial_map.query_error,
        [string]$Current.serial_map.query_error))
  }
  return $changes.ToArray()
}

function New-RoleMetrics {
  return [pscustomobject][ordered]@{
    present_observation_count=[long]0
    absent_observation_count=[long]0
    present_transition_count=[long]0
    absent_transition_count=[long]0
    started_false_observation_count=[long]0
    problem_observation_count=[long]0
    assigned_port_mismatch_observation_count=[long]0
    serial_map_mismatch_observation_count=[long]0
    query_error_observation_count=[long]0
    last_arrival_change_count=[long]0
    first_last_arrival_filetime_utc=$null
    final_last_arrival_filetime_utc=$null
  }
}

function New-MonitorState {
  param([Parameter(Mandatory = $true)]$EventStream,
        [Parameter(Mandatory = $true)][int]$CheckpointMs)
  return [pscustomobject]@{
    EventStream=$EventStream
    EventSequence=[long]0
    PollCount=[long]0
    StateChangeCount=[long]0
    CheckpointCount=[long]0
    QueryErrorPollCount=[long]0
    SerialMapAnomalyPollCount=[long]0
    MaximumPollDurationMs=[double]0
    TotalPollDurationMs=[double]0
    FirstPollDurationMs=$null
    PostReadyPollCount=[long]0
    MaximumPostReadyPollDurationMs=[double]0
    TotalPostReadyPollDurationMs=[double]0
    MaximumPollGapMs=[double]0
    LastPollElapsedMs=$null
    NextCheckpointElapsedMs=[double]$CheckpointMs
    CheckpointIntervalMs=[int]$CheckpointMs
    FirstSnapshot=$null
    LastSnapshot=$null
    LastSeenArrival=@{ vehicle=$null;ground=$null }
    RoleMetrics=@{
      vehicle=New-RoleMetrics
      ground=New-RoleMetrics
    }
  }
}

function Write-MonitorEvent {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Event,
    [Parameter(Mandatory = $true)][double]$ElapsedMs,
    [hashtable]$Details = @{}
  )
  $row = [ordered]@{
    schema_version=1
    sequence=[long]$State.EventSequence
    event=$Event
    elapsed_ms=[Math]::Round($ElapsedMs, 3)
    utc=[DateTime]::UtcNow.ToString('o')
  }
  foreach ($key in $Details.Keys) {
    if ($row.Contains($key)) {
      throw "Monitor event detail attempted to replace '$key'."
    }
    $row[$key] = $Details[$key]
  }
  Write-DurableJsonlRecord -Stream $State.EventStream -Value $row
  ++$State.EventSequence
}

function Add-MonitorObservation {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)]$Snapshot,
    [Parameter(Mandatory = $true)][double]$ElapsedMs,
    [Parameter(Mandatory = $true)][double]$PollDurationMs
  )
  ++$State.PollCount
  $State.TotalPollDurationMs += $PollDurationMs
  $State.MaximumPollDurationMs = [Math]::Max(
      $State.MaximumPollDurationMs, $PollDurationMs)
  if ($State.PollCount -eq 1) {
    $State.FirstPollDurationMs = $PollDurationMs
  } else {
    ++$State.PostReadyPollCount
    $State.TotalPostReadyPollDurationMs += $PollDurationMs
    $State.MaximumPostReadyPollDurationMs = [Math]::Max(
        $State.MaximumPostReadyPollDurationMs, $PollDurationMs)
  }
  [Nullable[double]]$pollGapMs = $null
  if ($null -ne $State.LastPollElapsedMs) {
    $pollGapMs = $ElapsedMs - [double]$State.LastPollElapsedMs
    $State.MaximumPollGapMs = [Math]::Max(
        $State.MaximumPollGapMs, [double]$pollGapMs)
  }
  $State.LastPollElapsedMs = $ElapsedMs

  [bool]$pollHasQueryError =
      -not [string]::IsNullOrEmpty([string]$Snapshot.serial_map.query_error)
  [bool]$serialMapAnomaly = $false
  foreach ($role in @('vehicle','ground')) {
    $current = $Snapshot.roles.$role
    $metrics = $State.RoleMetrics[$role]
    if ([bool]$current.present) {
      ++$metrics.present_observation_count
    } else {
      ++$metrics.absent_observation_count
    }
    if (-not [bool]$current.started) {
      ++$metrics.started_false_observation_count
    }
    if ([bool]$current.has_problem) {
      ++$metrics.problem_observation_count
    }
    if (-not [bool]$current.assigned_port_exact) {
      ++$metrics.assigned_port_mismatch_observation_count
    }
    if ([int]$current.serial_map_match_count -ne 1) {
      ++$metrics.serial_map_mismatch_observation_count
      $serialMapAnomaly = $true
    }
    if (-not [string]::IsNullOrEmpty([string]$current.query_error)) {
      ++$metrics.query_error_observation_count
      $pollHasQueryError = $true
    }
    $arrival = $current.last_arrival_filetime_utc
    if ($null -ne $arrival) {
      if ($null -eq $metrics.first_last_arrival_filetime_utc) {
        $metrics.first_last_arrival_filetime_utc = $arrival
      }
      if ($null -ne $State.LastSeenArrival[$role] -and
          [int64]$State.LastSeenArrival[$role] -ne [int64]$arrival) {
        ++$metrics.last_arrival_change_count
      }
      $State.LastSeenArrival[$role] = $arrival
      $metrics.final_last_arrival_filetime_utc = $arrival
    }
    if ($null -ne $State.LastSnapshot) {
      [bool]$wasPresent = [bool]$State.LastSnapshot.roles.$role.present
      if (-not $wasPresent -and [bool]$current.present) {
        ++$metrics.present_transition_count
      } elseif ($wasPresent -and -not [bool]$current.present) {
        ++$metrics.absent_transition_count
      }
    }
  }
  if ($pollHasQueryError) { ++$State.QueryErrorPollCount }
  if ($serialMapAnomaly) { ++$State.SerialMapAnomalyPollCount }

  if ($null -eq $State.FirstSnapshot) {
    $State.FirstSnapshot = $Snapshot
    Write-MonitorEvent -State $State -Event 'start' -ElapsedMs $ElapsedMs `
        -Details @{
          poll_number=[long]$State.PollCount
          poll_duration_ms=[Math]::Round($PollDurationMs, 3)
          poll_gap_ms=$null
          snapshot=$Snapshot
        }
  } else {
    [string[]]$changes = @(Compare-ContinuitySnapshots `
        -Previous $State.LastSnapshot -Current $Snapshot)
    if ($changes.Count -gt 0) {
      ++$State.StateChangeCount
      Write-MonitorEvent -State $State -Event 'state_change' `
          -ElapsedMs $ElapsedMs -Details @{
            poll_number=[long]$State.PollCount
            poll_duration_ms=[Math]::Round($PollDurationMs, 3)
            poll_gap_ms=if ($null -ne $pollGapMs) {
              [Math]::Round([double]$pollGapMs, 3)
            } else { $null }
            changes=$changes
            snapshot=$Snapshot
          }
    } elseif ($ElapsedMs -ge $State.NextCheckpointElapsedMs) {
      ++$State.CheckpointCount
      Write-MonitorEvent -State $State -Event 'checkpoint' `
          -ElapsedMs $ElapsedMs -Details @{
            poll_number=[long]$State.PollCount
            poll_duration_ms=[Math]::Round($PollDurationMs, 3)
            poll_gap_ms=if ($null -ne $pollGapMs) {
              [Math]::Round([double]$pollGapMs, 3)
            } else { $null }
            snapshot=$Snapshot
          }
    }
  }
  while ($State.NextCheckpointElapsedMs -le $ElapsedMs) {
    $State.NextCheckpointElapsedMs += $State.CheckpointIntervalMs
  }
  $State.LastSnapshot = $Snapshot
}

function Get-RoleSummary {
  param([Parameter(Mandatory = $true)]$Metrics)
  return [pscustomobject][ordered]@{
    present_observation_count=[long]$Metrics.present_observation_count
    absent_observation_count=[long]$Metrics.absent_observation_count
    present_transition_count=[long]$Metrics.present_transition_count
    absent_transition_count=[long]$Metrics.absent_transition_count
    started_false_observation_count=[long]$Metrics.started_false_observation_count
    problem_observation_count=[long]$Metrics.problem_observation_count
    assigned_port_mismatch_observation_count=
        [long]$Metrics.assigned_port_mismatch_observation_count
    serial_map_mismatch_observation_count=
        [long]$Metrics.serial_map_mismatch_observation_count
    query_error_observation_count=[long]$Metrics.query_error_observation_count
    last_arrival_change_count=[long]$Metrics.last_arrival_change_count
    first_last_arrival_filetime_utc=$Metrics.first_last_arrival_filetime_utc
    final_last_arrival_filetime_utc=$Metrics.final_last_arrival_filetime_utc
  }
}

function Test-ContinuityPreserved {
  param([Parameter(Mandatory = $true)]$State)
  if ($State.QueryErrorPollCount -ne 0 -or
      $State.SerialMapAnomalyPollCount -ne 0 -or
      $State.StateChangeCount -ne 0) { return $false }
  foreach ($role in @('vehicle','ground')) {
    $metrics = $State.RoleMetrics[$role]
    if ($metrics.absent_observation_count -ne 0 -or
        $metrics.started_false_observation_count -ne 0 -or
        $metrics.problem_observation_count -ne 0 -or
        $metrics.assigned_port_mismatch_observation_count -ne 0 -or
        $metrics.serial_map_mismatch_observation_count -ne 0 -or
        $metrics.query_error_observation_count -ne 0 -or
        $metrics.last_arrival_change_count -ne 0) { return $false }
  }
  return $true
}

function Complete-MonitorEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$StopReason,
    [Parameter(Mandatory = $true)][double]$ElapsedMs,
    [Parameter(Mandatory = $true)][string]$StartupMetadataSha256,
    [Parameter(Mandatory = $true)][bool]$ModeledOffline,
    [AllowEmptyString()][string]$ErrorMessage = ''
  )
  Write-MonitorEvent -State $State -Event 'stop' -ElapsedMs $ElapsedMs `
      -Details @{
        status=$Status;stop_reason=$StopReason;error=$ErrorMessage
        poll_count=[long]$State.PollCount;snapshot=$State.LastSnapshot
      }
  $State.EventStream.Flush($true)
  $State.EventStream.Dispose()
  [string]$eventsPath = Join-Path $Directory 'events.jsonl'
  [string]$eventsHash = Get-FileSha256 -Path $eventsPath
  $vehicleSummary = Get-RoleSummary -Metrics $State.RoleMetrics.vehicle
  $groundSummary = Get-RoleSummary -Metrics $State.RoleMetrics.ground
  [double]$averagePollDuration = if ($State.PollCount -gt 0) {
    $State.TotalPollDurationMs / [double]$State.PollCount
  } else { 0.0 }
  [double]$averagePostReadyPollDuration = if (
      $State.PostReadyPollCount -gt 0) {
    $State.TotalPostReadyPollDurationMs / [double]$State.PostReadyPollCount
  } else { 0.0 }
  $summary = [pscustomobject][ordered]@{
    schema_version=1
    monitor_id='VC-USB-COM-CONTINUITY-001'
    status=$Status
    completed_utc=[DateTime]::UtcNow.ToString('o')
    modeled_offline=$ModeledOffline
    stop_reason=$StopReason
    error=$ErrorMessage
    output_directory=$Directory
    expected_binding=[pscustomobject][ordered]@{
      vehicle=[pscustomobject][ordered]@{
        port=$VehiclePort;pnp_device_id=$VehiclePnpDeviceId
      }
      ground=[pscustomobject][ordered]@{
        port=$GroundPort;pnp_device_id=$GroundPnpDeviceId
      }
    }
    polling=[pscustomobject][ordered]@{
      interval_ms=$PollIntervalMs
      checkpoint_interval_ms=$CheckpointIntervalMs
      maximum_poll_duration_ms=[Math]::Round(
          $State.MaximumPollDurationMs, 3)
      average_poll_duration_ms=[Math]::Round($averagePollDuration, 3)
      first_poll_before_ready_ms=if ($null -ne $State.FirstPollDurationMs) {
        [Math]::Round([double]$State.FirstPollDurationMs, 3)
      } else { $null }
      post_ready_poll_count=[long]$State.PostReadyPollCount
      maximum_post_ready_poll_duration_ms=[Math]::Round(
          $State.MaximumPostReadyPollDurationMs, 3)
      average_post_ready_poll_duration_ms=[Math]::Round(
          $averagePostReadyPollDuration, 3)
      maximum_poll_gap_ms=[Math]::Round($State.MaximumPollGapMs, 3)
    }
    poll_count=[long]$State.PollCount
    event_count=[long]$State.EventSequence
    state_change_count=[long]$State.StateChangeCount
    checkpoint_count=[long]$State.CheckpointCount
    query_error_poll_count=[long]$State.QueryErrorPollCount
    serial_map_anomaly_poll_count=[long]$State.SerialMapAnomalyPollCount
    hardware_query_count=[long]$script:HardwareQueryCount
    native_identity_query_count=[long]$script:NativeIdentityQueryCount
    registry_query_count=[long]$script:RegistryQueryCount
    serial_port_open_count=[long]$script:SerialPortOpenCount
    no_com_ports_opened=($script:SerialPortOpenCount -eq 0)
    powercfg_invocation_count=[long]$script:PowerCfgInvocationCount
    startup_metadata_sha256=$StartupMetadataSha256
    events_sha256=$eventsHash
    continuity_preserved=Test-ContinuityPreserved -State $State
    roles=[pscustomobject][ordered]@{
      vehicle=$vehicleSummary
      ground=$groundSummary
    }
    first_snapshot=$State.FirstSnapshot
    final_snapshot=$State.LastSnapshot
  }
  [string]$summaryPath = Join-Path $Directory 'summary.json'
  Write-JsonDurableCreateNew -Path $summaryPath -Value $summary

  $hashRows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($name in @('startup_metadata.json','events.jsonl',
      'monitor_ready.json','summary.json')) {
    [string]$path = Join-Path $Directory $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $file = Get-Item -LiteralPath $path
      $hashRows.Add([pscustomobject][ordered]@{
        file=$name;size_bytes=[long]$file.Length
        sha256=Get-FileSha256 -Path $path
      })
    }
  }
  Write-JsonDurableCreateNew -Path (Join-Path $Directory `
      'artifact_hashes.json') -Value $hashRows.ToArray()
  return $summary
}

function Initialize-EvidenceDirectory {
  param([string]$RequestedDirectory)
  [string]$directory = $RequestedDirectory
  if ([string]::IsNullOrWhiteSpace($directory)) {
    [string]$repo = Split-Path -Parent $PSScriptRoot
    [string]$leaf = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') +
        '-pid' + [string]$PID)
    $directory = Join-Path $repo `
        ('runs\hil\USB-COM-CONTINUITY-001\' + $leaf)
  }
  $directory = [System.IO.Path]::GetFullPath($directory)
  [void][System.IO.Directory]::CreateDirectory($directory)
  foreach ($name in @('startup_metadata.json','events.jsonl',
      'monitor_ready.json','summary.json','artifact_hashes.json')) {
    if (Test-Path -LiteralPath (Join-Path $directory $name)) {
      throw "Evidence target already exists: $(Join-Path $directory $name)"
    }
  }
  return $directory
}

function New-ModeledRoleSnapshot {
  param(
    [string]$Role, [string]$Identity, [string]$ExpectedPort,
    [bool]$Present, [Nullable[int64]]$LastArrival,
    [string]$AssignedPort, [int]$SerialMapMatchCount
  )
  return [pscustomobject][ordered]@{
    role=$Role;pnp_device_id=$Identity;expected_port=$ExpectedPort
    present=$Present
    locate_configret=if ($Present) {[uint32]0} else {[uint32]13}
    status_configret=if ($Present) {[uint32]0} else {[uint32]::MaxValue}
    devnode_status=if ($Present) {[uint32]8} else {[uint32]0}
    started=$Present;has_problem=$false;problem_code=[uint32]0
    last_arrival_configret=if ($Present) {[uint32]0} else {[uint32]::MaxValue}
    last_arrival_filetime_utc=if ($Present) {$LastArrival} else {$null}
    last_arrival_utc=if ($Present) {
      [DateTime]::FromFileTimeUtc([int64]$LastArrival).ToString('o')
    } else { '' }
    assigned_port=$AssignedPort
    assigned_port_exact=[string]::Equals($AssignedPort, $ExpectedPort,
        [StringComparison]::OrdinalIgnoreCase)
    serial_map_match_count=$SerialMapMatchCount
    query_error=''
  }
}

function New-ModeledSnapshot {
  param(
    [bool]$GroundPresent,
    [int64]$GroundArrival,
    [int]$GroundMapCount
  )
  [int64]$vehicleArrival = 133485408000000000
  [string[]]$values = if (-not $GroundPresent) {
    @($VehiclePort)
  } elseif ($GroundMapCount -eq 2) {
    @($VehiclePort,$GroundPort,$GroundPort)
  } else {
    @($VehiclePort,$GroundPort)
  }
  return [pscustomobject][ordered]@{
    roles=[pscustomobject][ordered]@{
      vehicle=New-ModeledRoleSnapshot -Role 'vehicle' `
          -Identity $VehiclePnpDeviceId -ExpectedPort $VehiclePort `
          -Present $true -LastArrival $vehicleArrival `
          -AssignedPort $VehiclePort -SerialMapMatchCount 1
      ground=New-ModeledRoleSnapshot -Role 'ground' `
          -Identity $GroundPnpDeviceId -ExpectedPort $GroundPort `
          -Present $GroundPresent -LastArrival $GroundArrival `
          -AssignedPort $GroundPort -SerialMapMatchCount $GroundMapCount
    }
    serial_map=[pscustomobject][ordered]@{
      values=$values;entries=@();query_error=''
    }
  }
}

function Invoke-DiskOnlySelfTest {
  [string]$directory = Initialize-EvidenceDirectory `
      -RequestedDirectory $SelfTestEvidenceDirectory
  $startup = New-ModeledStartupPowerMetadata
  [string]$startupPath = Join-Path $directory 'startup_metadata.json'
  Write-JsonDurableCreateNew -Path $startupPath -Value $startup
  [string]$startupHash = Get-FileSha256 -Path $startupPath
  $eventStream = New-DurableJsonlStream -Path (Join-Path $directory `
      'events.jsonl')
  $state = New-MonitorState -EventStream $eventStream `
      -CheckpointMs $CheckpointIntervalMs
  [int64]$arrival0 = 133485408100000000
  [int64]$arrival1 = 133485408200000000
  $fixtures = @(
    [pscustomobject]@{ms=0.0;duration=0.05;snapshot=(
      New-ModeledSnapshot -GroundPresent $true -GroundArrival $arrival0 `
          -GroundMapCount 1)},
    [pscustomobject]@{ms=100.0;duration=0.04;snapshot=(
      New-ModeledSnapshot -GroundPresent $true -GroundArrival $arrival0 `
          -GroundMapCount 1)},
    [pscustomobject]@{ms=200.0;duration=0.04;snapshot=(
      New-ModeledSnapshot -GroundPresent $false -GroundArrival $arrival0 `
          -GroundMapCount 0)},
    [pscustomobject]@{ms=300.0;duration=0.06;snapshot=(
      New-ModeledSnapshot -GroundPresent $true -GroundArrival $arrival1 `
          -GroundMapCount 1)},
    [pscustomobject]@{ms=400.0;duration=0.04;snapshot=(
      New-ModeledSnapshot -GroundPresent $true -GroundArrival $arrival1 `
          -GroundMapCount 2)},
    [pscustomobject]@{ms=500.0;duration=0.04;snapshot=(
      New-ModeledSnapshot -GroundPresent $true -GroundArrival $arrival1 `
          -GroundMapCount 1)}
  )
  foreach ($fixture in $fixtures) {
    Add-MonitorObservation -State $state -Snapshot $fixture.snapshot `
        -ElapsedMs ([double]$fixture.ms) `
        -PollDurationMs ([double]$fixture.duration)
    if ($state.PollCount -eq 1) {
      Write-JsonDurableCreateNew -Path (Join-Path $directory `
          'monitor_ready.json') -Value ([pscustomobject][ordered]@{
            schema_version=1;status='READY';modeled_offline=$true
            ready_utc='2030-01-01T00:00:00.0000000Z'
            startup_metadata_sha256=$startupHash
            first_event_sequence=0
            serial_port_open_count=[long]$script:SerialPortOpenCount
          })
    }
  }
  $summary = Complete-MonitorEvidence -Directory $directory -State $state `
      -Status 'COMPLETE' -StopReason 'selftest_complete' -ElapsedMs 500.0 `
      -StartupMetadataSha256 $startupHash -ModeledOffline $true
  Write-Host (('FINAL COMPLETE output={0} events={1} polls={2} ' +
      'hardware_queries={3} COM_opens={4}') -f $directory,
      $summary.event_count, $summary.poll_count,
      $summary.hardware_query_count, $summary.serial_port_open_count)
}

# SelfTest returns before native type initialization, powercfg, PNP/registry
# enumeration, process watching, or any possible live-device access.
if ($SelfTest) {
  Invoke-DiskOnlySelfTest
  return
}

function Invoke-LiveMonitor {
  [string]$directory = Initialize-EvidenceDirectory `
      -RequestedDirectory $OutputDirectory
  $startup = Get-StartupPowerMetadata
  [string]$startupPath = Join-Path $directory 'startup_metadata.json'
  Write-JsonDurableCreateNew -Path $startupPath -Value $startup
  [string]$startupHash = Get-FileSha256 -Path $startupPath
  $eventStream = New-DurableJsonlStream -Path (Join-Path $directory `
      'events.jsonl')
  $state = New-MonitorState -EventStream $eventStream `
      -CheckpointMs $CheckpointIntervalMs
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $watchedProcess = $null
  [string]$status = 'COMPLETE'
  [string]$stopReason = 'duration_elapsed'
  [string]$errorMessage = ''
  try {
    Initialize-NativeDeviceProbeType
    if ($WatchProcessId -gt 0) {
      $watchedProcess = [System.Diagnostics.Process]::GetProcessById(
          $WatchProcessId)
    }
    $pollWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $snapshot = Get-LiveContinuitySnapshot
    $pollWatch.Stop()
    Add-MonitorObservation -State $state -Snapshot $snapshot `
        -ElapsedMs $watch.Elapsed.TotalMilliseconds `
        -PollDurationMs $pollWatch.Elapsed.TotalMilliseconds
    Write-JsonDurableCreateNew -Path (Join-Path $directory `
        'monitor_ready.json') -Value ([pscustomobject][ordered]@{
          schema_version=1;status='READY';modeled_offline=$false
          ready_utc=[DateTime]::UtcNow.ToString('o')
          process_id=[int]$PID
          startup_metadata_sha256=$startupHash
          first_event_sequence=0
          serial_port_open_count=[long]$script:SerialPortOpenCount
        })
    Write-Host (('MONITOR_READY output={0} pid={1} power_scheme={2} ' +
        'USB_selective_AC={3} USB3_LPM_AC={4}') -f $directory, $PID,
        $startup.active_power_scheme.guid,
        $startup.usb_selective_suspend.ac_interpretation,
        $startup.usb3_link_power_management.ac_interpretation)

    [double]$nextPollMs = [double]$PollIntervalMs
    while ($true) {
      if ($watch.Elapsed.TotalSeconds -ge $DurationSeconds) {
        $stopReason = 'duration_elapsed'
        break
      }
      if (-not [string]::IsNullOrWhiteSpace($StopSignalPath) -and
          (Test-Path -LiteralPath $StopSignalPath -PathType Leaf)) {
        $stopReason = 'stop_signal_observed'
        break
      }
      if ($null -ne $watchedProcess -and $watchedProcess.HasExited) {
        $stopReason = 'watched_process_exited'
        break
      }
      [double]$remainingMs = $nextPollMs - $watch.Elapsed.TotalMilliseconds
      if ($remainingMs -gt 1.0) {
        Start-Sleep -Milliseconds ([int][Math]::Floor($remainingMs))
      }
      if ($watch.Elapsed.TotalMilliseconds -lt $nextPollMs) {
        continue
      }
      $pollWatch.Restart()
      $snapshot = Get-LiveContinuitySnapshot
      $pollWatch.Stop()
      Add-MonitorObservation -State $state -Snapshot $snapshot `
          -ElapsedMs $watch.Elapsed.TotalMilliseconds `
          -PollDurationMs $pollWatch.Elapsed.TotalMilliseconds
      do { $nextPollMs += [double]$PollIntervalMs } while (
          $nextPollMs -le $watch.Elapsed.TotalMilliseconds)
    }
  } catch {
    $status = 'ERROR'
    $stopReason = 'monitor_exception'
    $errorMessage = $_.Exception.ToString()
    try {
      Write-MonitorEvent -State $state -Event 'error' `
          -ElapsedMs $watch.Elapsed.TotalMilliseconds `
          -Details @{error=$errorMessage}
    } catch {
      $errorMessage += '; error_record_write_failed=' + $_.Exception.Message
    }
  } finally {
    if ($null -ne $watchedProcess) { $watchedProcess.Dispose() }
  }
  $watch.Stop()
  $summary = Complete-MonitorEvidence -Directory $directory -State $state `
      -Status $status -StopReason $stopReason `
      -ElapsedMs $watch.Elapsed.TotalMilliseconds `
      -StartupMetadataSha256 $startupHash -ModeledOffline $false `
      -ErrorMessage $errorMessage
  Write-Host (('FINAL {0} output={1} reason={2} polls={3} changes={4} ' +
      'LastArrival(V/G)={5}/{6} COM_opens={7}') -f $summary.status,
      $directory, $summary.stop_reason, $summary.poll_count,
      $summary.state_change_count,
      $summary.roles.vehicle.last_arrival_change_count,
      $summary.roles.ground.last_arrival_change_count,
      $summary.serial_port_open_count)
  if ($status -eq 'ERROR') { exit 2 }
}

Invoke-LiveMonitor
