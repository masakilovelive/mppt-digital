[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ExecutablePath,
  [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
  [Parameter(Mandatory = $true)][string]$ExpectedLauncherSha256,
  [Parameter(Mandatory = $true)][string]$ArgumentsFile,
  [Parameter(Mandatory = $true)][string]$ExpectedArgumentsFileSha256,
  [Parameter(Mandatory = $true)][string]$BoundFilePath,
  [Parameter(Mandatory = $true)][string]$ExpectedBoundFileSha256,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$Purpose,
  [switch]$TestFailAfterStart,
  [switch]$TestFailJobCreationBeforeStart,
  [switch]$TestFailJobAssignment,
  [ValidateRange(0, 10000)][int]$TestPauseBeforeProcessStartMs = 0,
  [string]$TestPreStartReadyMarker = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$launcherFailureExitCode = 125
$jobTypeSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace VcEvidenceLauncherV4 {
  public static class HandlePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern UInt32 GetFinalPathNameByHandle(
      SafeFileHandle handle, StringBuilder path, UInt32 length, UInt32 flags);

    public static string GetFinalPath(SafeFileHandle handle) {
      UInt32 length = 512;
      while (true) {
        var path = new StringBuilder((int)length);
        UInt32 result = GetFinalPathNameByHandle(handle, path, length, 0);
        if (result == 0) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (result < length) return path.ToString();
        length = result + 1;
      }
    }
  }

  public sealed class KillOnCloseJob : IDisposable {
    private IntPtr handle;
    private const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const Int32 JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
      public Int64 PerProcessUserTimeLimit;
      public Int64 PerJobUserTimeLimit;
      public UInt32 LimitFlags;
      public UIntPtr MinimumWorkingSetSize;
      public UIntPtr MaximumWorkingSetSize;
      public UInt32 ActiveProcessLimit;
      public UIntPtr Affinity;
      public UInt32 PriorityClass;
      public UInt32 SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
      public UInt64 ReadOperationCount;
      public UInt64 WriteOperationCount;
      public UInt64 OtherOperationCount;
      public UInt64 ReadTransferCount;
      public UInt64 WriteTransferCount;
      public UInt64 OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
      public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
      public IO_COUNTERS IoInfo;
      public UIntPtr ProcessMemoryLimit;
      public UIntPtr JobMemoryLimit;
      public UIntPtr PeakProcessMemoryUsed;
      public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
      IntPtr job, Int32 informationClass, IntPtr information,
      UInt32 informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(
      IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public KillOnCloseJob() {
      handle = CreateJobObject(IntPtr.Zero, null);
      if (handle == IntPtr.Zero) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      info.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
      IntPtr pointer = Marshal.AllocHGlobal(length);
      try {
        Marshal.StructureToPtr(info, pointer, false);
        if (!SetInformationJobObject(handle,
              JobObjectExtendedLimitInformation, pointer, (UInt32)length)) {
          throw new Win32Exception(Marshal.GetLastWin32Error());
        }
      } finally {
        Marshal.FreeHGlobal(pointer);
      }
    }

    public void Assign(Process process) {
      if (handle == IntPtr.Zero) throw new ObjectDisposedException("job");
      if (!AssignProcessToJobObject(handle, process.Handle)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
    }

    public void Terminate(UInt32 exitCode) {
      if (handle == IntPtr.Zero) return;
      if (!TerminateJobObject(handle, exitCode)) {
        int error = Marshal.GetLastWin32Error();
        if (error != 5) throw new Win32Exception(error);
      }
    }

    public void Dispose() {
      if (handle != IntPtr.Zero) {
        CloseHandle(handle);
        handle = IntPtr.Zero;
      }
      GC.SuppressFinalize(this);
    }

    ~KillOnCloseJob() { Dispose(); }
  }
}
'@

if ($null -eq ('VcEvidenceLauncherV4.KillOnCloseJob' -as [type])) {
  Add-Type -TypeDefinition $jobTypeSource -Language CSharp
}

function Assert-Sha256Text {
  param([string]$Name, [string]$Value)
  if ($Value -notmatch '^[0-9A-Fa-f]{64}$') {
    throw "$Name must be exactly 64 hexadecimal characters"
  }
}

function Get-Sha256FromBytes {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Get-Sha256FromStream {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Stream.Position = 0
    $hash = ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '')
    $Stream.Position = 0
    return $hash
  } finally {
    $sha.Dispose()
  }
}

function Get-Sha256FromFileReadOnly {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = New-Object System.IO.FileStream(
      $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read, 4096,
      [System.IO.FileOptions]::SequentialScan)
  try {
    return Get-Sha256FromStream -Stream $stream
  } finally {
    $stream.Dispose()
  }
}

function Assert-NoReparsePointInPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($fullPath)
  $current = $root
  $relative = $fullPath.Substring($root.Length)
  $segments = $relative.Split(
      [char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
  foreach ($segment in $segments) {
    $current = [IO.Path]::Combine($current, $segment)
    $attributes = [IO.File]::GetAttributes($current)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "EXECUTABLE_REPARSE_POINT_REFUSED component=$current"
    }
  }
}

function Get-NormalizedFinalHandlePath {
  param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)
  $path = [VcEvidenceLauncherV4.HandlePath]::GetFinalPath(
      $Stream.SafeFileHandle)
  if ($path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    return '\\' + $path.Substring(8)
  }
  if ($path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    return $path.Substring(4)
  }
  return $path
}

function Write-BytesCreateNew {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
  )
  $stream = New-Object System.IO.FileStream(
      $Path, [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read,
      4096, [System.IO.FileOptions]::WriteThrough)
  try {
    if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-TextCreateNew {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  Write-BytesCreateNew -Path $Path -Bytes $encoding.GetBytes($Text)
}

function Write-JsonCreateNew {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value,
    [int]$Depth = 14
  )
  Write-TextCreateNew -Path $Path `
      -Text (($Value | ConvertTo-Json -Depth $Depth) +
        [Environment]::NewLine)
}

function ConvertTo-WindowsCommandLineArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $backslashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') { $backslashes++; continue }
    if ($character -eq '"') {
      if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
      }
      [void]$builder.Append('\"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$builder.Append(('\' * $backslashes))
      $backslashes = 0
    }
    [void]$builder.Append($character)
  }
  if ($backslashes -gt 0) {
    [void]$builder.Append(('\' * ($backslashes * 2)))
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Get-ArtifactRecord {
  param([string]$Directory, [string]$Name)
  $path = Join-Path $Directory $Name
  $item = Get-Item -LiteralPath $path
  return [pscustomobject][ordered]@{
    file = $Name
    size_bytes = [long]$item.Length
    sha256 = Get-Sha256FromFileReadOnly -Path $path
  }
}

function Complete-LaunchEvidence {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Context,
    [Parameter(Mandatory = $true)][string]$Outcome,
    [AllowNull()][object]$ChildExitCode = $null,
    [string]$FailureMessage = ''
  )

  $output = [string]$Context.OutputDirectory
  $failureMode = $Outcome.StartsWith('LAUNCHER_FAILURE_',
      [StringComparison]::Ordinal)
  $processStarted = [bool]$Context.ProcessStarted
  $waitCompleted = [bool]$Context.WaitCompleted
  $actualExitCaptured = ($processStarted -and $waitCompleted -and
      $null -ne $ChildExitCode)
  $actualExitCode = if ($actualExitCaptured) {
    [int]$ChildExitCode
  } else { $null }
  $lifecycle = [pscustomobject][ordered]@{
    schema_version = 4
    status = $Outcome
    process_started = $processStarted
    pid = if ($processStarted) { [int]$Context.Pid } else { $null }
    started_utc = if ($processStarted) {
      [string]$Context.StartedUtc
    } else { $null }
    wait_completed = $waitCompleted
    wait_completed_utc = [string]$Context.WaitCompletedUtc
    elapsed_ms = [double]$Context.ElapsedMs
    has_exited_after_wait = [bool]($processStarted -and $waitCompleted)
    actual_os_exit_code_captured = $actualExitCaptured
    actual_os_exit_code = $actualExitCode
    exit_code_capture_order = if ($actualExitCaptured) {
      'Process.WaitForExit(); stream-copy waits; Process.Refresh(); Process.ExitCode'
    } else { 'NOT_APPLICABLE_CHILD_NOT_STARTED' }
    job_object_kill_on_close = [bool]$Context.JobCreated
    job_assignment_completed = [bool]$Context.JobAssigned
    kill_requested_after_start_failure = [bool]$Context.KillRequested
    child_waited_after_start_failure = [bool]$Context.WaitedAfterFailure
    launcher_failure = if ($failureMode) { $FailureMessage } else { $null }
    executable_sha256 = [string]$Context.ExecutableSha256
    launcher_sha256 = [string]$Context.LauncherSha256
    bound_file_sha256 = [string]$Context.BoundFileSha256
    bound_file_opened_before_hash = [bool]$true
    bound_file_lock_share_mode = 'FileShare.Read'
    bound_file_final_handle_path = [string]$Context.BoundFileFinalHandlePath
    bound_file_final_handle_path_exact_match = [bool]$true
    bound_file_reparse_components_checked_before_and_after_open = [bool]$true
    bound_file_reparse_path_refused = [bool]$true
    arguments_snapshot_sha256 = [string]$Context.ArgumentsSnapshotSha256
    executable_opened_before_hash = [bool]$true
    executable_lock_share_mode = 'FileShare.Read'
    executable_final_handle_path = [string]$Context.ExecutableFinalHandlePath
    executable_final_handle_path_exact_match = [bool]$true
    executable_reparse_path_refused = [bool]$true
    executable_lock_release_stage = 'outer finally after sealed evidence attempt'
    logs_streamed_during_child_lifetime = $processStarted
    log_observer_share_mode = 'FileShare.Read'
    logs_fsynced_after_wait = $waitCompleted
    bound_file_lock_release_stage = 'outer finally after sealed evidence attempt'
  }
  Write-JsonCreateNew -Path (Join-Path $output 'process_lifecycle.json') `
      -Value $lifecycle

  $childResult = if ($failureMode) {
    $Outcome
  } elseif ($ChildExitCode -eq 0) {
    'CHILD_EXIT_ZERO'
  } else {
    'CHILD_EXIT_NONZERO'
  }
  $summary = [pscustomobject][ordered]@{
    schema_version = 4
    contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCH-004'
    status = $childResult
    evidence_complete = [bool]$true
    purpose = [string]$Context.Purpose
    launcher_failure_exit_code = if ($failureMode) { 125 } else { $null }
    child_actual_os_exit_code = $actualExitCode
    child_exit_code_captured_after_wait = $actualExitCaptured
    child_killed_and_waited = [bool]($failureMode -and
      $Context.KillRequested -and $Context.WaitedAfterFailure)
    child_not_started = [bool](-not $processStarted)
    pid = if ($processStarted) { [int]$Context.Pid } else { $null }
    started_utc = if ($processStarted) {
      [string]$Context.StartedUtc
    } else { $null }
    finished_utc = [string]$Context.WaitCompletedUtc
    duration_ms = [double]$Context.ElapsedMs
    launcher_sha256 = [string]$Context.LauncherSha256
    executable_sha256 = [string]$Context.ExecutableSha256
    bound_file_sha256 = [string]$Context.BoundFileSha256
    arguments_snapshot_sha256 = [string]$Context.ArgumentsSnapshotSha256
    arguments_copied_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.argv.json')
    executable_opened_before_hash = [bool]$true
    executable_lock_share_mode = 'FileShare.Read'
    executable_final_handle_path = [string]$Context.ExecutableFinalHandlePath
    executable_reparse_path_refused = [bool]$true
    executable_lock_release_stage = 'outer finally after sealed evidence attempt'
    bound_file_opened_before_hash = [bool]$true
    bound_file_lock_share_mode = 'FileShare.Read'
    bound_file_final_handle_path = [string]$Context.BoundFileFinalHandlePath
    bound_file_final_handle_path_exact_match = [bool]$true
    bound_file_reparse_components_checked_before_and_after_open = [bool]$true
    bound_file_reparse_path_refused = [bool]$true
    bound_file_lock_release_stage = 'outer finally after sealed evidence attempt'
    launcher_external_actions = [pscustomobject][ordered]@{
      power_cycle = [bool]$false
      upload = [bool]$false
      com_open_by_launcher = [bool]$false
    }
    failure_message = if ($failureMode) { $FailureMessage } else { $null }
  }
  Write-JsonCreateNew -Path (Join-Path $output 'summary.json') -Value $summary

  $coveredNames = @(
    'launch.argv.json', 'launch.pid.txt', 'launch.preflight.json',
    'launch.stderr.log', 'launch.stdout.log',
    'process_lifecycle.json', 'summary.json')
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($name in $coveredNames) {
    $records.Add((Get-ArtifactRecord -Directory $output -Name $name))
  }
  $artifactManifest = [pscustomobject][ordered]@{
    schema_version = 4
    contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCH-004'
    coverage = 'all seven runtime evidence files present before artifact_manifest.json'
    covered_file_count = 7
    files = $records.ToArray()
  }
  $artifactPath = Join-Path $output 'artifact_manifest.json'
  Write-JsonCreateNew -Path $artifactPath -Value $artifactManifest
  $artifactHash = Get-Sha256FromFileReadOnly -Path $artifactPath

  $manifest = [pscustomobject][ordered]@{
    schema_version = 4
    contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCH-004'
    status = if ($failureMode) {
      'SEALED_LAUNCHER_FAILURE'
    } else { 'EVIDENCE_COMPLETE' }
    child_result = $childResult
    child_actual_os_exit_code = $actualExitCode
    actual_exit_code_capture = if ($actualExitCaptured) {
      'CAPTURED_AFTER_WAIT'
    } else { 'NOT_APPLICABLE_CHILD_NOT_STARTED' }
    launcher_failure_exit_code = if ($failureMode) { 125 } else { $null }
    purpose = [string]$Context.Purpose
    runtime_artifact_coverage = '7/7'
    artifact_manifest_sha256 = $artifactHash
    summary_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'summary.json')
    process_lifecycle_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'process_lifecycle.json')
    launch_argv_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.argv.json')
    launch_preflight_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.preflight.json')
    launch_pid_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.pid.txt')
    launch_stdout_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.stdout.log')
    launch_stderr_sha256 = Get-Sha256FromFileReadOnly `
        -Path (Join-Path $output 'launch.stderr.log')
    launcher_sha256 = [string]$Context.LauncherSha256
    executable_sha256 = [string]$Context.ExecutableSha256
    bound_file_sha256 = [string]$Context.BoundFileSha256
    arguments_snapshot_sha256 = [string]$Context.ArgumentsSnapshotSha256
    executable_lock_share_mode = 'FileShare.Read'
    executable_reparse_path_refused = [bool]$true
    executable_lock_release_stage = 'outer finally after sealed evidence attempt'
    bound_file_lock_share_mode = 'FileShare.Read'
    bound_file_final_handle_path = [string]$Context.BoundFileFinalHandlePath
    bound_file_final_handle_path_exact_match = [bool]$true
    bound_file_reparse_components_checked_before_and_after_open = [bool]$true
    bound_file_reparse_path_refused = [bool]$true
    job_object_kill_on_close = [bool]$Context.JobCreated
    bound_file_lock_release_stage = 'outer finally after sealed evidence attempt'
  }
  $manifestPath = Join-Path $output 'manifest.json'
  Write-JsonCreateNew -Path $manifestPath -Value $manifest
  $manifestHash = Get-Sha256FromFileReadOnly -Path $manifestPath
  Write-TextCreateNew -Path (Join-Path $output 'manifest.sha256') `
      -Text ("$manifestHash *manifest.json" + [Environment]::NewLine)

  $seal = [pscustomobject][ordered]@{
    schema_version = 4
    contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCH-004'
    status = if ($failureMode) {
      'SEALED_LAUNCHER_FAILURE'
    } else { 'SEALED_EVIDENCE_COMPLETE' }
    child_actual_os_exit_code = $actualExitCode
    launcher_failure_exit_code = if ($failureMode) { 125 } else { $null }
    manifest_sha256 = $manifestHash
    artifact_manifest_sha256 = $artifactHash
    summary_sha256 = $manifest.summary_sha256
    process_lifecycle_sha256 = $manifest.process_lifecycle_sha256
    launch_argv_sha256 = $manifest.launch_argv_sha256
    launch_preflight_sha256 = $manifest.launch_preflight_sha256
    launch_pid_sha256 = $manifest.launch_pid_sha256
    launch_stdout_sha256 = $manifest.launch_stdout_sha256
    launch_stderr_sha256 = $manifest.launch_stderr_sha256
    launcher_sha256 = [string]$Context.LauncherSha256
    executable_sha256 = [string]$Context.ExecutableSha256
    bound_file_sha256 = [string]$Context.BoundFileSha256
    arguments_snapshot_sha256 = [string]$Context.ArgumentsSnapshotSha256
    executable_lock_share_mode = 'FileShare.Read'
    executable_reparse_path_refused = [bool]$true
    executable_lock_release_stage = 'outer finally after sealed evidence attempt'
    bound_file_lock_share_mode = 'FileShare.Read'
    bound_file_final_handle_path = [string]$Context.BoundFileFinalHandlePath
    bound_file_final_handle_path_exact_match = [bool]$true
    bound_file_reparse_components_checked_before_and_after_open = [bool]$true
    bound_file_reparse_path_refused = [bool]$true
    runtime_artifact_covered_file_count = 7
    bound_file_lock_release_stage = 'outer finally after sealed evidence attempt'
    sealed_utc = [DateTime]::UtcNow.ToString('o')
  }
  $sealPath = Join-Path $output 'final_seal.json'
  Write-JsonCreateNew -Path $sealPath -Value $seal
  $sealHash = Get-Sha256FromFileReadOnly -Path $sealPath
  Write-TextCreateNew -Path (Join-Path $output 'final_seal.sha256') `
      -Text ("$sealHash *final_seal.json" + [Environment]::NewLine)
}

$outputCreated = $false
$childStarted = $false
$jobCreated = $false
$jobAssigned = $false
$completionAttempted = $false
$killRequested = $false
$waitedAfterFailure = $false
$process = $null
$job = $null
$stdoutStream = $null
$stderrStream = $null
$stdoutCopyTask = $null
$stderrCopyTask = $null
$executableLockStream = $null
$boundFileLockStream = $null
$stopwatch = $null
$startedUtc = $null
$waitCompletedUtc = $null
$pidValue = 0
$childExitCode = $null
$executableFinalHandlePath = $null
$boundFileFinalHandlePath = $null
$launcherReturnCode = $null

try {
  foreach ($hashInput in @(
      @('ExpectedExecutableSha256', $ExpectedExecutableSha256),
      @('ExpectedLauncherSha256', $ExpectedLauncherSha256),
      @('ExpectedArgumentsFileSha256', $ExpectedArgumentsFileSha256),
      @('ExpectedBoundFileSha256', $ExpectedBoundFileSha256))) {
    Assert-Sha256Text -Name $hashInput[0] -Value $hashInput[1]
  }

  $ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
  $ArgumentsFile = [System.IO.Path]::GetFullPath($ArgumentsFile)
  $BoundFilePath = [System.IO.Path]::GetFullPath($BoundFilePath)
  $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
  $launcherPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  if (-not [string]::IsNullOrWhiteSpace($TestPreStartReadyMarker)) {
    $TestPreStartReadyMarker = [IO.Path]::GetFullPath(
        $TestPreStartReadyMarker)
    $testMarkerParent = Split-Path -Parent $TestPreStartReadyMarker
    if (-not (Test-Path -LiteralPath $testMarkerParent -PathType Container)) {
      throw "TestPreStartReadyMarker parent must exist: $testMarkerParent"
    }
    if (Test-Path -LiteralPath $TestPreStartReadyMarker) {
      throw "TestPreStartReadyMarker must be absent: $TestPreStartReadyMarker"
    }
  }

  if (Test-Path -LiteralPath $OutputDirectory) {
    throw "OutputDirectory must be fresh and absent: $OutputDirectory"
  }
  foreach ($inputPath in @($ExecutablePath, $launcherPath,
      $ArgumentsFile, $BoundFilePath)) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
      throw "Required input is not a file: $inputPath"
    }
  }

  $launcherSha256 = Get-Sha256FromFileReadOnly -Path $launcherPath
  Assert-NoReparsePointInPath -Path $ExecutablePath
  $executableLockStream = New-Object IO.FileStream(
      $ExecutablePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
      [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
  Assert-NoReparsePointInPath -Path $ExecutablePath
  $executableFinalHandlePath = Get-NormalizedFinalHandlePath `
      -Stream $executableLockStream
  if (-not [string]::Equals(
        [IO.Path]::GetFullPath($ExecutablePath),
        [IO.Path]::GetFullPath($executableFinalHandlePath),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw ('EXECUTABLE_REPARSE_POINT_REFUSED requested={0} final={1}' -f
      $ExecutablePath, $executableFinalHandlePath)
  }
  $executableSha256 = Get-Sha256FromStream -Stream $executableLockStream
  if ($launcherSha256 -ne $ExpectedLauncherSha256.ToUpperInvariant()) {
    throw ('LAUNCHER_HASH_MISMATCH expected={0} actual={1}' -f
      $ExpectedLauncherSha256.ToUpperInvariant(), $launcherSha256)
  }
  if ($executableSha256 -ne $ExpectedExecutableSha256.ToUpperInvariant()) {
    throw ('EXECUTABLE_HASH_MISMATCH expected={0} actual={1}' -f
      $ExpectedExecutableSha256.ToUpperInvariant(), $executableSha256)
  }

  [byte[]]$argumentsSnapshotBytes =
      [System.IO.File]::ReadAllBytes($ArgumentsFile)
  $argumentsSnapshotSha256 = Get-Sha256FromBytes `
      -Bytes $argumentsSnapshotBytes
  if ($argumentsSnapshotSha256 -ne
      $ExpectedArgumentsFileSha256.ToUpperInvariant()) {
    throw ('ARGUMENTS_SNAPSHOT_MISMATCH expected={0} actual={1}' -f
      $ExpectedArgumentsFileSha256.ToUpperInvariant(),
      $argumentsSnapshotSha256)
  }
  $throwOnInvalidBytes = [bool]$true
  $strictUtf8 = New-Object System.Text.UTF8Encoding(
      $false, $throwOnInvalidBytes)
  try {
    $argumentsSnapshotText = $strictUtf8.GetString($argumentsSnapshotBytes)
  } catch [System.Text.DecoderFallbackException] {
    throw 'INVALID_UTF8_ARGUMENTS_SNAPSHOT'
  }
  if ($argumentsSnapshotText.Length -gt 0 -and
      $argumentsSnapshotText[0] -eq [char]0xFEFF) {
    $argumentsSnapshotText = $argumentsSnapshotText.Substring(1)
  }
  $trimmedArguments = $argumentsSnapshotText.Trim()
  if (-not ($trimmedArguments.StartsWith('[') -and
            $trimmedArguments.EndsWith(']'))) {
    throw 'ArgumentsFile snapshot root must be a JSON array'
  }
  $parsedArguments = $argumentsSnapshotText | ConvertFrom-Json
  $arguments = New-Object 'System.Collections.Generic.List[string]'
  foreach ($argument in @($parsedArguments)) {
    if (-not ($argument -is [string])) {
      throw 'Every ArgumentsFile entry must be a JSON string'
    }
    $arguments.Add([string]$argument)
  }
  if ($arguments.Count -eq 0) {
    throw 'ArgumentsFile must contain at least one argument'
  }

  $boundOccurrenceCount = 0
  for ($index = 0; $index -lt $arguments.Count; $index++) {
    if ([string]::Equals($arguments[$index], $BoundFilePath,
          [StringComparison]::OrdinalIgnoreCase)) {
      $boundOccurrenceCount++
    }
  }
  if ($boundOccurrenceCount -ne 1) {
    throw ('BoundFilePath must occur exactly once in snapshot; count={0}' -f
      $boundOccurrenceCount)
  }

  $executableLeaf = [System.IO.Path]::GetFileName($ExecutablePath)
  $isPowerShellFileLaunch = $executableLeaf -match '^(powershell|pwsh)(\.exe)?$'
  $effectiveBoundArgumentIndex = $null
  $powerShellPrefixExact = $false
  $expectedPowerShellPrefix = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
  if ($isPowerShellFileLaunch) {
    $fileSwitchIndices = New-Object 'System.Collections.Generic.List[int]'
    for ($index = 0; $index -lt $arguments.Count; $index++) {
      if ([string]::Equals($arguments[$index], '-File',
            [StringComparison]::OrdinalIgnoreCase)) {
        $fileSwitchIndices.Add($index)
      }
    }
    if ($fileSwitchIndices.Count -ne 1) {
      throw ('PowerShell arguments require exactly one explicit -File; count={0}' -f
        $fileSwitchIndices.Count)
    }
    if ($arguments.Count -lt 5) {
      throw 'PowerShell live argv is shorter than the exact approved prefix'
    }
    for ($index = 0; $index -lt $expectedPowerShellPrefix.Count; $index++) {
      if (-not [string]::Equals($arguments[$index],
            $expectedPowerShellPrefix[$index],
            [StringComparison]::OrdinalIgnoreCase)) {
        throw ('POWERSHELL_LIVE_PREFIX_MISMATCH index={0} expected={1} actual={2}' -f
          $index, $expectedPowerShellPrefix[$index], $arguments[$index])
      }
    }
    $effectiveBoundArgumentIndex = 4
    if ($fileSwitchIndices[0] -ne 3 -or
        -not [string]::Equals($arguments[4], $BoundFilePath,
          [StringComparison]::OrdinalIgnoreCase)) {
      throw 'PowerShell exact -File prefix does not resolve to BoundFilePath'
    }
    $powerShellPrefixExact = $true
  }

  Assert-NoReparsePointInPath -Path $BoundFilePath
  $boundFileLockStream = New-Object System.IO.FileStream(
      $BoundFilePath, [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read,
      4096, [System.IO.FileOptions]::SequentialScan)
  Assert-NoReparsePointInPath -Path $BoundFilePath
  $boundFileFinalHandlePath = Get-NormalizedFinalHandlePath `
      -Stream $boundFileLockStream
  if (-not [string]::Equals(
        [IO.Path]::GetFullPath($BoundFilePath),
        [IO.Path]::GetFullPath($boundFileFinalHandlePath),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw ('BOUND_FILE_REPARSE_POINT_REFUSED requested={0} final={1}' -f
      $BoundFilePath, $boundFileFinalHandlePath)
  }
  $boundFileSha256 = Get-Sha256FromStream -Stream $boundFileLockStream
  if ($boundFileSha256 -ne $ExpectedBoundFileSha256.ToUpperInvariant()) {
    throw ('BOUND_FILE_HASH_MISMATCH expected={0} actual={1}' -f
      $ExpectedBoundFileSha256.ToUpperInvariant(), $boundFileSha256)
  }

  $outputParent = Split-Path -Parent $OutputDirectory
  if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "OutputDirectory parent must already exist: $outputParent"
  }
  [void](New-Item -ItemType Directory -Path $OutputDirectory `
      -ErrorAction Stop)
  $outputCreated = $true

  $launchArgvPath = Join-Path $OutputDirectory 'launch.argv.json'
  Write-BytesCreateNew -Path $launchArgvPath `
      -Bytes $argumentsSnapshotBytes

  $createdUtc = [DateTime]::UtcNow.ToString('o')
  $preflight = [pscustomobject][ordered]@{
    schema_version = 4
    contract_id = 'EVIDENCE-BOUND-CHILD-LAUNCH-004'
    checked_utc = $createdUtc
    status = 'PASS_HASH_BOUND_CHILD_AUTHORIZED'
    purpose = $Purpose
    output_directory = $OutputDirectory
    output_was_absent = [bool]$true
    launcher = [pscustomobject][ordered]@{
      path = $launcherPath
      sha256 = $launcherSha256
      expected_sha256 = $ExpectedLauncherSha256.ToUpperInvariant()
      exact_match = [bool]$true
    }
    executable = [pscustomobject][ordered]@{
      path = $ExecutablePath
      sha256 = $executableSha256
      expected_sha256 = $ExpectedExecutableSha256.ToUpperInvariant()
      exact_match = [bool]$true
      opened_before_hash = [bool]$true
      lock_share_mode = 'FileShare.Read'
      lock_held_until_child_exit = [bool]$true
      lock_release_stage = 'outer finally after sealed evidence attempt'
      final_handle_path = $executableFinalHandlePath
      final_handle_path_exact_match = [bool]$true
      reparse_components_checked_before_and_after_open = [bool]$true
      reparse_path_refused = [bool]$true
    }
    arguments_snapshot = [pscustomobject][ordered]@{
      source_path = $ArgumentsFile
      source_read_operation = 'ReadAllBytes exactly once'
      byte_count = [long]$argumentsSnapshotBytes.Length
      sha256 = $argumentsSnapshotSha256
      expected_sha256 = $ExpectedArgumentsFileSha256.ToUpperInvariant()
      strict_utf8 = [bool]$true
      parsed_entry_count = [int]$arguments.Count
      same_bytes_copied_to = 'launch.argv.json'
    }
    bound_file = [pscustomobject][ordered]@{
      path = $BoundFilePath
      sha256 = $boundFileSha256
      expected_sha256 = $ExpectedBoundFileSha256.ToUpperInvariant()
      opened_before_hash = [bool]$true
      lock_share_mode = 'FileShare.Read'
      lock_held_until_child_exit = [bool]$true
      final_handle_path = $boundFileFinalHandlePath
      final_handle_path_exact_match = [bool]$true
      reparse_components_checked_before_and_after_open = [bool]$true
      reparse_path_refused = [bool]$true
      lock_release_stage = 'outer finally after sealed evidence attempt'
      snapshot_occurrence_count = $boundOccurrenceCount
      powershell_file_launch = [bool]$isPowerShellFileLaunch
      effective_argument_index = $effectiveBoundArgumentIndex
    }
    powershell_execution = [pscustomobject][ordered]@{
      applicable = [bool]$isPowerShellFileLaunch
      exact_live_prefix = $expectedPowerShellPrefix
      exact_live_prefix_match = [bool]$powerShellPrefixExact
      file_switch_index = if ($isPowerShellFileLaunch) { 3 } else { $null }
      bound_file_argument_index = $effectiveBoundArgumentIndex
      competing_mode_before_file_allowed = [bool]$false
    }
    launcher_external_actions = [pscustomobject][ordered]@{
      power_cycle = [bool]$false
      upload = [bool]$false
      com_open_by_launcher = [bool]$false
    }
    job_object = [pscustomobject][ordered]@{
      limit = 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'
      creation_required_before_child_start = [bool]$true
      assignment_required_immediately_after_start = [bool]$true
    }
    test_fail_after_start_requested = [bool]$TestFailAfterStart
    test_fail_job_creation_before_start_requested =
        [bool]$TestFailJobCreationBeforeStart
    test_fail_job_assignment_requested = [bool]$TestFailJobAssignment
    test_pause_before_process_start_ms = $TestPauseBeforeProcessStartMs
    test_pre_start_ready_marker = if (
        [string]::IsNullOrWhiteSpace($TestPreStartReadyMarker)) {
      $null
    } else { [IO.Path]::GetFullPath($TestPreStartReadyMarker) }
  }
  $preflightPath = Join-Path $OutputDirectory 'launch.preflight.json'
  Write-JsonCreateNew -Path $preflightPath -Value $preflight

  $quotedArguments = New-Object 'System.Collections.Generic.List[string]'
  foreach ($argument in $arguments.ToArray()) {
    $quotedArguments.Add((ConvertTo-WindowsCommandLineArgument `
          -Value $argument))
  }
  $commandLine = $quotedArguments.ToArray() -join ' '
  $logObserverShareMode = [System.IO.FileShare]::Read
  $stdoutPath = Join-Path $OutputDirectory 'launch.stdout.log'
  $stderrPath = Join-Path $OutputDirectory 'launch.stderr.log'
  $stdoutStream = New-Object System.IO.FileStream(
      $stdoutPath, [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write, $logObserverShareMode,
      1, [System.IO.FileOptions]::WriteThrough)
  $stderrStream = New-Object System.IO.FileStream(
      $stderrPath, [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write, $logObserverShareMode,
      1, [System.IO.FileOptions]::WriteThrough)

  if ($TestFailJobCreationBeforeStart) {
    throw 'TEST_FAIL_JOB_CREATION_BEFORE_START_INJECTED'
  }
  $job = New-Object VcEvidenceLauncherV4.KillOnCloseJob
  $jobCreated = $true
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $ExecutablePath
  $startInfo.Arguments = $commandLine
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not [string]::IsNullOrWhiteSpace($TestPreStartReadyMarker)) {
    Write-TextCreateNew -Path $TestPreStartReadyMarker `
        -Text ("READY_BEFORE_PROCESS_START launcher_pid=$PID" +
          [Environment]::NewLine)
  }
  if ($TestPauseBeforeProcessStartMs -gt 0) {
    Start-Sleep -Milliseconds $TestPauseBeforeProcessStartMs
  }
  $startedUtc = [DateTime]::UtcNow
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  if (-not $process.Start()) { throw 'Process.Start returned false' }
  $childStarted = $true
  $pidValue = [int]$process.Id
  if ($TestFailJobAssignment) {
    throw 'TEST_FAIL_JOB_ASSIGNMENT_INJECTED'
  }
  $job.Assign($process)
  $jobAssigned = $true
  Write-TextCreateNew -Path (Join-Path $OutputDirectory 'launch.pid.txt') `
      -Text ($pidValue.ToString([Globalization.CultureInfo]::InvariantCulture) +
        [Environment]::NewLine)
  $stdoutCopyTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
  $stderrCopyTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

  if ($TestFailAfterStart) {
    throw 'TEST_FAIL_AFTER_START_INJECTED'
  }

  $process.WaitForExit()
  $stdoutCopyTask.Wait()
  $stderrCopyTask.Wait()
  $waitCompletedUtc = [DateTime]::UtcNow
  $stopwatch.Stop()
  $process.Refresh()
  $childExitCode = [int]$process.ExitCode
  $stdoutStream.Flush($true)
  $stderrStream.Flush($true)
  $stdoutStream.Dispose(); $stdoutStream = $null
  $stderrStream.Dispose(); $stderrStream = $null
  $job.Dispose(); $job = $null

  $context = @{
    OutputDirectory = $OutputDirectory
    Purpose = $Purpose
    Pid = $pidValue
    StartedUtc = $startedUtc.ToString('o')
    WaitCompletedUtc = $waitCompletedUtc.ToString('o')
    ElapsedMs = [double]$stopwatch.Elapsed.TotalMilliseconds
    JobAssigned = $jobAssigned
    KillRequested = $false
    WaitedAfterFailure = $false
    ProcessStarted = $true
    WaitCompleted = $true
    JobCreated = $jobCreated
    LauncherSha256 = $launcherSha256
    ExecutableSha256 = $executableSha256
    ExecutableFinalHandlePath = $executableFinalHandlePath
    BoundFileSha256 = $boundFileSha256
    BoundFileFinalHandlePath = $boundFileFinalHandlePath
    ArgumentsSnapshotSha256 = $argumentsSnapshotSha256
  }
  $completionAttempted = $true
  Complete-LaunchEvidence -Context $context -Outcome 'CHILD_COMPLETED' `
      -ChildExitCode $childExitCode
  Write-Host ('EVIDENCE_COMPLETE child_exit={0} output={1}' -f
    $childExitCode, $OutputDirectory)
} catch {
  $failureMessage = $_.Exception.Message
  if ($outputCreated -and -not $completionAttempted) {
    try {
      if ($childStarted) {
        if ($null -ne $process -and -not $process.HasExited) {
          $killRequested = $true
          if ($jobAssigned -and $null -ne $job) {
            $job.Terminate([uint32]$launcherFailureExitCode)
          } else {
            $process.Kill()
          }
        }
        if ($null -ne $process) {
          $process.WaitForExit()
          $waitedAfterFailure = $true
        }
        if ($null -ne $stdoutCopyTask) {
          try { $stdoutCopyTask.Wait() } catch {}
        }
        if ($null -ne $stderrCopyTask) {
          try { $stderrCopyTask.Wait() } catch {}
        }
        $waitCompletedUtc = [DateTime]::UtcNow
        if ($null -ne $stopwatch) { $stopwatch.Stop() }
        if ($null -ne $process) {
          $process.Refresh()
          $childExitCode = [int]$process.ExitCode
        }
      } else {
        $waitCompletedUtc = [DateTime]::UtcNow
        $childExitCode = $null
      }
      if ($null -ne $stdoutStream) {
        $stdoutStream.Flush($true); $stdoutStream.Dispose(); $stdoutStream = $null
      }
      if ($null -ne $stderrStream) {
        $stderrStream.Flush($true); $stderrStream.Dispose(); $stderrStream = $null
      }
      if ($null -ne $job) { $job.Dispose(); $job = $null }

      $pidPath = Join-Path $OutputDirectory 'launch.pid.txt'
      if (-not (Test-Path -LiteralPath $pidPath)) {
        $pidText = if ($childStarted) {
          $pidValue.ToString([Globalization.CultureInfo]::InvariantCulture)
        } else { 'NOT_STARTED' }
        Write-TextCreateNew -Path $pidPath -Text ($pidText +
            [Environment]::NewLine)
      }
      $context = @{
        OutputDirectory = $OutputDirectory
        Purpose = $Purpose
        Pid = $pidValue
        StartedUtc = if ($childStarted) {
          $startedUtc.ToString('o')
        } else { $null }
        WaitCompletedUtc = $waitCompletedUtc.ToString('o')
        ElapsedMs = if ($null -ne $stopwatch) {
          [double]$stopwatch.Elapsed.TotalMilliseconds
        } else { 0.0 }
        JobAssigned = $jobAssigned
        JobCreated = $jobCreated
        KillRequested = $killRequested
        WaitedAfterFailure = $waitedAfterFailure
        ProcessStarted = $childStarted
        WaitCompleted = [bool]($childStarted -and $waitedAfterFailure)
        LauncherSha256 = $launcherSha256
        ExecutableSha256 = $executableSha256
        ExecutableFinalHandlePath = $executableFinalHandlePath
        BoundFileSha256 = $boundFileSha256
        BoundFileFinalHandlePath = $boundFileFinalHandlePath
        ArgumentsSnapshotSha256 = $argumentsSnapshotSha256
      }
      $failureOutcome = if ($childStarted) {
        'LAUNCHER_FAILURE_AFTER_START'
      } else { 'LAUNCHER_FAILURE_BEFORE_START' }
      $completionAttempted = $true
      Complete-LaunchEvidence -Context $context `
          -Outcome $failureOutcome `
          -ChildExitCode $childExitCode -FailureMessage $failureMessage
      [Console]::Error.WriteLine(
          ('SEALED_LAUNCHER_FAILURE output={0} message={1}' -f
            $OutputDirectory, $failureMessage))
    } catch {
      [Console]::Error.WriteLine(
          ('POST_START_FAILURE_SEAL_ERROR original={0} seal={1}' -f
            $failureMessage, $_.Exception.Message))
    }
  } else {
    if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
    if ($null -ne $stderrStream) { $stderrStream.Dispose() }
    if ($null -ne $job) { $job.Dispose() }
  }
  [Console]::Error.WriteLine(
      ('LAUNCHER_REFUSED_OR_FAILED message={0}' -f $failureMessage))
  $launcherReturnCode = $launcherFailureExitCode
} finally {
  if ($null -ne $executableLockStream) {
    $executableLockStream.Dispose()
    $executableLockStream = $null
  }
  if ($null -ne $boundFileLockStream) {
    $boundFileLockStream.Dispose()
    $boundFileLockStream = $null
  }
  if ($null -ne $job) {
    $job.Dispose()
    $job = $null
  }
  if ($null -ne $process) { $process.Dispose() }
}

if ($null -ne $launcherReturnCode) { exit $launcherReturnCode }
exit $childExitCode
