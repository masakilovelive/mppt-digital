[CmdletBinding()]
param(
  [string]$RunnerPath = '',
  [string]$EvidenceDirectory = '',
  [switch]$SourcePathProbeChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($RunnerPath)) {
  $RunnerPath = Join-Path $repo 'tools\run_dual_diag_param_list_hil.ps1'
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $EvidenceDirectory = Join-Path $repo `
      ('runs\validation\HIL-DUAL-DIAG-PARAM-LIST-RUNNER-CONTRACT-001\' +
       $stamp)
}
$EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

if (-not ('VcParamListRunnerContractPathBinding.HandlePath' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace VcParamListRunnerContractPathBinding {
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
}
'@
}

function Assert-NoReparsePointInPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )
  [string]$fullPath = [System.IO.Path]::GetFullPath($Path)
  [string]$root = [System.IO.Path]::GetPathRoot($fullPath)
  [string]$current = $root
  [string]$relative = $fullPath.Substring($root.Length)
  [string[]]$segments = $relative.Split(
      [char[]]@('\', '/'),
      [System.StringSplitOptions]::RemoveEmptyEntries)
  foreach ($segment in $segments) {
    $current = [System.IO.Path]::Combine($current, $segment)
    $attributes = [System.IO.File]::GetAttributes($current)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw ('{0}_REPARSE_POINT_REFUSED component={1}' -f
        $Label, $current)
    }
  }
}

function Get-NormalizedFinalHandlePath {
  param([Parameter(Mandatory = $true)][System.IO.FileStream]$Stream)
  [string]$path =
      [VcParamListRunnerContractPathBinding.HandlePath]::GetFinalPath(
        $Stream.SafeFileHandle)
  if ($path.StartsWith('\\?\UNC\',
      [System.StringComparison]::OrdinalIgnoreCase)) {
    return '\\' + $path.Substring(8)
  }
  if ($path.StartsWith('\\?\',
      [System.StringComparison]::OrdinalIgnoreCase)) {
    return $path.Substring(4)
  }
  return $path
}

function Write-BytesDurable {
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

function Write-TextDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
  )
  Write-BytesDurable -Path $Path -Bytes $utf8NoBom.GetBytes($Text)
}

function Write-JsonDurable {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 30
  Write-TextDurable -Path $Path -Text ($json + [Environment]::NewLine)
}

function Get-BoundStreamBytes {
  param([Parameter(Mandatory = $true)][System.IO.FileStream]$Stream)
  if ($Stream.Length -gt [int]::MaxValue) {
    throw 'Bound source exceeds supported byte-array length.'
  }
  [long]$originalPosition = $Stream.Position
  try {
    $Stream.Position = 0
    [byte[]]$bytes = New-Object byte[] ([int]$Stream.Length)
    [int]$offset = 0
    while ($offset -lt $bytes.Length) {
      [int]$read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) { throw 'Unexpected EOF reading bound source.' }
      $offset += $read
    }
    return $bytes
  } finally {
    $Stream.Position = $originalPosition
  }
}

function Get-BytesSha256 {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')
  } finally {
    $sha.Dispose()
  }
}

function Test-WriteOpenDeniedByBinding {
  param([Parameter(Mandatory = $true)][string]$Path)
  $writeProbe = $null
  try {
    $writeProbe = New-Object System.IO.FileStream($Path,
        [System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite)
    return $false
  } catch [System.IO.IOException] {
    return $true
  } finally {
    if ($null -ne $writeProbe) { $writeProbe.Dispose() }
  }
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
  throw "Evidence directory already exists; refusing overwrite: $EvidenceDirectory"
}
[void][System.IO.Directory]::CreateDirectory($EvidenceDirectory)

$checkerPath = $PSCommandPath
$checkerSha256 = ''
$runnerInitialSha256 = ''
$checkerBoundStream = $null
$runnerBoundStream = $null
[byte[]]$checkerBoundBytes = [byte[]]@()
[byte[]]$runnerBoundBytes = [byte[]]@()
[long]$checkerInitialSize = 0
[long]$runnerInitialSize = 0
[bool]$checkerWriteOpenDenied = $false
[bool]$runnerWriteOpenDenied = $false
[string]$checkerFinalHandlePath = ''
[string]$runnerFinalHandlePath = ''
[int]$runnerChildProcessStartCount = 0
[int]$sourcePathProbeCheckerProcessStartCount = 0
$sourceBindingChildRows = New-Object 'System.Collections.Generic.List[object]'
trap {
  [string]$checkerError = "checker infrastructure error: $($_.Exception.Message)"
  [string]$checkerExceptionType = $_.Exception.GetType().FullName
  [string]$checkerScriptStackTrace = [string]$_.ScriptStackTrace
  [string]$checkerPositionMessage = [string]$_.InvocationInfo.PositionMessage
  try {
    $errorPath = Join-Path $EvidenceDirectory 'checker_error.json'
    if (-not (Test-Path -LiteralPath $errorPath)) {
      Write-JsonDurable -Path $errorPath -Value ([ordered]@{
        schema_version=3;status='ERROR';completed=$false
        written_utc=[DateTime]::UtcNow.ToString('o')
        checker_path=$checkerPath;checker_sha256=$checkerSha256
        runner_path=$RunnerPath
        source_path_probe_child=[bool]$SourcePathProbeChild
        runner_child_process_start_count=$runnerChildProcessStartCount
        source_path_probe_checker_process_start_count=
          $sourcePathProbeCheckerProcessStartCount
        error=$checkerError;exception_type=$checkerExceptionType
        script_stack_trace=$checkerScriptStackTrace
        position_message=$checkerPositionMessage
      })
    }
  } catch {}
  if ($null -ne $runnerBoundStream) { $runnerBoundStream.Dispose() }
  if ($null -ne $checkerBoundStream) { $checkerBoundStream.Dispose() }
  [Console]::Error.WriteLine($checkerError)
  exit 2
}

Assert-NoReparsePointInPath -Path $checkerPath -Label 'CHECKER_SOURCE'
$checkerBoundStream = New-Object System.IO.FileStream($checkerPath,
    [System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
Assert-NoReparsePointInPath -Path $checkerPath -Label 'CHECKER_SOURCE'
$checkerFinalHandlePath = Get-NormalizedFinalHandlePath `
    -Stream $checkerBoundStream
if (-not [string]::Equals(
      [System.IO.Path]::GetFullPath($checkerPath),
      [System.IO.Path]::GetFullPath($checkerFinalHandlePath),
      [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ('CHECKER_SOURCE_FINAL_HANDLE_PATH_MISMATCH requested={0} final={1}' -f
    $checkerPath, $checkerFinalHandlePath)
}
$checkerBoundBytes = Get-BoundStreamBytes -Stream $checkerBoundStream
$checkerSha256 = Get-BytesSha256 -Bytes $checkerBoundBytes
$checkerInitialSize = [long]$checkerBoundBytes.LongLength
$checkerWriteOpenDenied = Test-WriteOpenDeniedByBinding -Path $checkerPath
Write-BytesDurable -Path (Join-Path $EvidenceDirectory `
    'bound_checker_source.ps1') -Bytes $checkerBoundBytes

$startedUtc = [DateTime]::UtcNow.ToString('o')
$checks = New-Object 'System.Collections.Generic.List[object]'
$failures = New-Object 'System.Collections.Generic.List[string]'
$childStdout = ''
$childStderr = ''
$childExitCode = $null

function Add-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Passed,
    [Parameter(Mandatory = $true)][string]$Detail
  )
  $checks.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
      })
  if (-not $Passed) {
    $failures.Add("$Name`: $Detail")
  }
}

[string]$checkerSource = $utf8Strict.GetString($checkerBoundBytes)
$checkerTokens = $null
$checkerParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $checkerSource, $checkerPath, [ref]$checkerTokens,
    [ref]$checkerParseErrors)
Add-Check -Name 'checker_bound_source_ast_parse' `
    -Passed (@($checkerParseErrors).Count -eq 0) `
    -Detail ('parse_error_count=' + @($checkerParseErrors).Count)
[string]$checkerDiskStartSha = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $checkerPath).Hash
[long]$checkerDiskStartSize = (Get-Item -LiteralPath $checkerPath).Length
Add-Check -Name 'checker_bound_source_start_exact' `
    -Passed ($checkerDiskStartSha -ceq $checkerSha256 -and
      $checkerDiskStartSize -eq $checkerInitialSize) `
    -Detail ('bound_sha=' + $checkerSha256 + ' disk_sha=' +
      $checkerDiskStartSha + ' size=' + $checkerDiskStartSize)
Add-Check -Name 'checker_source_write_open_denied_while_bound' `
    -Passed $checkerWriteOpenDenied `
    -Detail 'Checker source is held FileShare.Read; a concurrent write handle must be denied.'
Add-Check -Name 'checker_source_reparse_free_final_handle_exact' `
    -Passed ([string]::Equals(
      [System.IO.Path]::GetFullPath($checkerPath),
      [System.IO.Path]::GetFullPath($checkerFinalHandlePath),
      [System.StringComparison]::OrdinalIgnoreCase)) `
    -Detail ('requested=' + $checkerPath + ' final=' +
      $checkerFinalHandlePath + ' all_components_checked_pre_post=true')

$bindingProbePath = Join-Path $EvidenceDirectory `
    'source_binding_model_target.bin'
[byte[]]$bindingProbeBytes = $utf8NoBom.GetBytes(
    'unbound-red-to-bound-green-source-binding-probe')
Write-BytesDurable -Path $bindingProbePath -Bytes $bindingProbeBytes
[string]$bindingProbeShaBefore = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $bindingProbePath).Hash
[bool]$unboundWriteOpenSucceeded = -not (
    Test-WriteOpenDeniedByBinding -Path $bindingProbePath)
$bindingProbeStream = New-Object System.IO.FileStream($bindingProbePath,
    [System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
try {
  [bool]$boundWriteOpenDenied = Test-WriteOpenDeniedByBinding `
      -Path $bindingProbePath
  [string]$bindingProbeShaWhileBound = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $bindingProbePath).Hash
} finally {
  $bindingProbeStream.Dispose()
}
[string]$bindingProbeShaAfter = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $bindingProbePath).Hash
$sourceBindingModel = [ordered]@{
  schema_version=1
  model='unbound mutation-open RED then FileShare.Read-bound GREEN'
  target_file='source_binding_model_target.bin'
  unbound_write_open_succeeded=$unboundWriteOpenSucceeded
  bound_write_open_denied=$boundWriteOpenDenied
  content_sha256_before=$bindingProbeShaBefore
  content_sha256_while_bound=$bindingProbeShaWhileBound
  content_sha256_after=$bindingProbeShaAfter
  content_unchanged=($bindingProbeShaBefore -ceq $bindingProbeShaWhileBound -and
    $bindingProbeShaBefore -ceq $bindingProbeShaAfter)
}
Write-JsonDurable -Path (Join-Path $EvidenceDirectory `
    'source_binding_model.json') -Value $sourceBindingModel
Add-Check -Name 'source_binding_unbound_red_then_bound_green_model' `
    -Passed ($unboundWriteOpenSucceeded -and $boundWriteOpenDenied -and
      $sourceBindingModel.content_unchanged) `
    -Detail 'An unbound source admits a write handle; the same target bound FileShare.Read rejects it without changing bytes.'

$sourceBindingRedRelative =
    'runs\validation\HIL-DUAL-DIAG-PARAM-LIST-RUNNER-POSTQUERY-MATCHER-RED-004\20260827T160021532Z-transition-branch-red'
$sourceBindingRedDirectory = Join-Path $repo $sourceBindingRedRelative
$sourceBindingRedSummaryPath = Join-Path $sourceBindingRedDirectory `
    'summary.json'
$sourceBindingRedSealPath = Join-Path $sourceBindingRedDirectory `
    'final_seal.json'
[string]$expectedBindingRedSummarySha =
    '1552D4E1966117C6E30E067BD3D545E2BCF09F1BB9C6BB2CF263E6FEC6766317'
[string]$expectedBindingRedSealSha =
    '6464CD626B676288900D935D518610B6A19B64E6B1A96A968CE3D070B4DED56B'
$sourceBindingRedSummary = Get-Content -Raw -LiteralPath `
    $sourceBindingRedSummaryPath | ConvertFrom-Json
[string]$bindingRedSummarySha = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $sourceBindingRedSummaryPath).Hash
[string]$bindingRedSealSha = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $sourceBindingRedSealPath).Hash
[object[]]$oldBindingChecks = @($sourceBindingRedSummary.checks |
    Where-Object {$_.name -match
      'source_bound|source_binding|write_open_denied'})
$sourceBindingRedBaseline = [ordered]@{
  schema_version=1
  classification='durable pre-binding RED baseline'
  evidence_directory=$sourceBindingRedRelative
  summary_sha256=$bindingRedSummarySha
  final_seal_sha256=$bindingRedSealSha
  status=[string]$sourceBindingRedSummary.status
  check_count=@($sourceBindingRedSummary.checks).Count
  failure_count=[int]$sourceBindingRedSummary.failure_count
  checker_sha256=[string]$sourceBindingRedSummary.checker_sha256
  runner_sha256=[string]$sourceBindingRedSummary.runner_sha256
  source_binding_named_check_count=$oldBindingChecks.Count
  red_reason='old checker reopened runner/checker without a held source binding and had zero source-binding checks'
  unbound_write_open_succeeded=$unboundWriteOpenSucceeded
}
Write-JsonDurable -Path (Join-Path $EvidenceDirectory `
    'source_binding_red_baseline.json') -Value $sourceBindingRedBaseline
Add-Check -Name 'source_binding_prior_red_baseline_exact' `
    -Passed ($bindingRedSummarySha -ceq $expectedBindingRedSummarySha -and
      $bindingRedSealSha -ceq $expectedBindingRedSealSha -and
      [string]$sourceBindingRedSummary.status -ceq 'RED' -and
      [string]$sourceBindingRedSummary.checker_sha256 -ceq
        '17D722FA99EA9EEC1980297068A4638678107AB88FA2CBD2E567B887CA511E29' -and
      $oldBindingChecks.Count -eq 0 -and $unboundWriteOpenSucceeded) `
    -Detail ('old_checker=' + $sourceBindingRedSummary.checker_sha256 +
      ' old_binding_checks=' + $oldBindingChecks.Count +
      ' unbound_write_open=' + $unboundWriteOpenSucceeded)

function Invoke-RunnerReparsePathProbe {
  param(
    [Parameter(Mandatory = $true)][string]$CheckerPath,
    [Parameter(Mandatory = $true)][string]$ParentEvidenceDirectory
  )
  [string]$tempRoot =
      [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') +
      '\'
  [string]$scratch = Join-Path $tempRoot `
      ('vc_param_runner_checker_reparse_' +
       [guid]::NewGuid().ToString('N'))
  [string]$realDirectory = Join-Path $scratch 'real_runner'
  [string]$junctionDirectory = Join-Path $scratch 'junction_runner'
  [string]$dummyRunnerPath = Join-Path $realDirectory 'probe_runner.ps1'
  [string]$probeEvidence = Join-Path $ParentEvidenceDirectory `
      'runner_reparse_probe_child'
  [string]$stdoutTmp = Join-Path $ParentEvidenceDirectory `
      'runner_reparse_probe_stdout.tmp'
  [string]$stderrTmp = Join-Path $ParentEvidenceDirectory `
      'runner_reparse_probe_stderr.tmp'
  [string]$stdoutText = ''
  [string]$stderrText = ''
  [int]$probeExitCode = -1
  [string]$junctionAttributes = ''
  [bool]$junctionWasReparsePoint = $false
  $childError = $null
  try {
    [void][System.IO.Directory]::CreateDirectory($realDirectory)
    Write-TextDurable -Path $dummyRunnerPath `
        -Text "param()`r`nexit 99`r`n"
    $junctionItem = New-Item -ItemType Junction -Path $junctionDirectory `
        -Target $realDirectory -ErrorAction Stop
    $junctionAttributes = [string]$junctionItem.Attributes
    $junctionWasReparsePoint = (($junctionItem.Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    [string]$junctionRunnerPath = Join-Path $junctionDirectory `
        'probe_runner.ps1'
    [string]$savedPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      ++$script:sourcePathProbeCheckerProcessStartCount
      & powershell.exe -NoProfile -ExecutionPolicy Bypass `
          -File $CheckerPath -SourcePathProbeChild `
          -RunnerPath $junctionRunnerPath `
          -EvidenceDirectory $probeEvidence `
          1> $stdoutTmp 2> $stderrTmp
      $probeExitCode = [int]$LASTEXITCODE
    } finally {
      $ErrorActionPreference = $savedPreference
    }
    $stdoutText = if (Test-Path -LiteralPath $stdoutTmp) {
      Get-Content -Raw -LiteralPath $stdoutTmp
    } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrTmp) {
      Get-Content -Raw -LiteralPath $stderrTmp
    } else { '' }
    $childErrorPath = Join-Path $probeEvidence 'checker_error.json'
    if (Test-Path -LiteralPath $childErrorPath -PathType Leaf) {
      $childError = Get-Content -Raw -LiteralPath $childErrorPath |
          ConvertFrom-Json
    }
    [int]$runnerSelftestDirectoryCount = if (
        Test-Path -LiteralPath $probeEvidence -PathType Container) {
      @(Get-ChildItem -LiteralPath $probeEvidence -Directory |
        Where-Object {$_.Name -like 'runner_selftest_*'}).Count
    } else { 0 }
    return [pscustomobject][ordered]@{
      schema_version=1
      junction_path=$junctionDirectory
      junction_target=$realDirectory
      junction_attributes=$junctionAttributes
      junction_reparse_point=$junctionWasReparsePoint
      runner_path=$junctionRunnerPath
      checker_exit_code=$probeExitCode
      checker_error=if($null -ne $childError){$childError.error}else{$null}
      checker_error_runner_child_process_start_count=
        if($null -ne $childError){
          $childError.runner_child_process_start_count
        }else{$null}
      runner_selftest_directory_count=$runnerSelftestDirectoryCount
      child_summary_exists=(Test-Path -LiteralPath `
        (Join-Path $probeEvidence 'summary.json') -PathType Leaf)
      stdout=$stdoutText
      stderr=$stderrText
      valid=($junctionWasReparsePoint -and $probeExitCode -eq 2 -and
        $null -ne $childError -and
        [string]$childError.error -match
          'RUNNER_REPARSE_POINT_REFUSED component=' -and
        [int]$childError.runner_child_process_start_count -eq 0 -and
        $runnerSelftestDirectoryCount -eq 0 -and
        -not (Test-Path -LiteralPath `
          (Join-Path $probeEvidence 'summary.json') -PathType Leaf))
    }
  } finally {
    Remove-Item -LiteralPath $stdoutTmp, $stderrTmp -Force `
        -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $junctionDirectory) {
      $junctionCleanupItem = Get-Item -Force -LiteralPath $junctionDirectory
      if (($junctionCleanupItem.Attributes -band
          [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'Reparse probe cleanup target was not a reparse point.'
      }
      [System.IO.Directory]::Delete($junctionDirectory, $false)
    }
    if (Test-Path -LiteralPath $scratch) {
      [string]$resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
      [string]$scratchLeaf = Split-Path -Leaf $resolvedScratch
      if (-not $resolvedScratch.StartsWith($tempRoot,
          [System.StringComparison]::OrdinalIgnoreCase) -or
          -not $scratchLeaf.StartsWith('vc_param_runner_checker_reparse_',
            [System.StringComparison]::Ordinal)) {
        throw 'Reparse probe cleanup containment check failed.'
      }
      [System.IO.Directory]::Delete($resolvedScratch, $true)
    }
  }
}

$sourcePathReparseProbe = $null
if (-not $SourcePathProbeChild) {
  $sourcePathReparseProbe = Invoke-RunnerReparsePathProbe `
      -CheckerPath $checkerPath `
      -ParentEvidenceDirectory $EvidenceDirectory
  Write-JsonDurable -Path (Join-Path $EvidenceDirectory `
      'source_path_reparse_probe.json') -Value $sourcePathReparseProbe
  Add-Check -Name 'runner_junction_rejected_before_child_start' `
      -Passed ([bool]$sourcePathReparseProbe.valid) `
      -Detail ('exit=' + $sourcePathReparseProbe.checker_exit_code +
        ' runner_child_count=' +
        $sourcePathReparseProbe.checker_error_runner_child_process_start_count +
        ' error=' + $sourcePathReparseProbe.checker_error)
}

function Assert-SourcePattern {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Description
  )
  $matched = $script:source -match $Pattern
  Add-Check -Name $Name -Passed $matched -Detail $Description
}

function Get-FunctionText {
  param($Ast, [Parameter(Mandatory = $true)][string]$Name)
  $matches = @($Ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $Name
    }, $true))
  if ($matches.Count -ne 1) { return '' }
  return [string]($matches[0].Extent.Text)
}

function Invoke-RunnerJsonSerializationProbe {
  param(
    [Parameter(Mandatory = $true)]$RunnerAst,
    [Parameter(Mandatory = $true)][string]$Directory
  )
  [string]$bytesFunction = Get-FunctionText -Ast $RunnerAst `
      -Name 'Write-BytesDurable'
  [string]$textFunction = Get-FunctionText -Ast $RunnerAst `
      -Name 'Write-TextDurable'
  [string]$jsonFunction = Get-FunctionText -Ast $RunnerAst `
      -Name 'Write-JsonDurable'
  if ([string]::IsNullOrWhiteSpace($bytesFunction) -or
      [string]::IsNullOrWhiteSpace($textFunction) -or
      [string]::IsNullOrWhiteSpace($jsonFunction)) {
    throw 'Runner durable JSON helper dependency extraction failed.'
  }
  if (Test-Path -LiteralPath $Directory) {
    throw "JSON serialization probe directory exists: $Directory"
  }
  [void][System.IO.Directory]::CreateDirectory($Directory)
  [string]$escapedDirectory = $Directory.Replace("'", "''")
  [string]$probeScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
$bytesFunction
$textFunction
$jsonFunction
`$probeDirectory = '$escapedDirectory'
[object[]]`$empty = @()
[object[]]`$singleton = @([pscustomobject][ordered]@{event='one';value=1})
[object[]]`$multiple = @(
  [pscustomobject][ordered]@{event='one';value=1},
  [pscustomobject][ordered]@{event='two';value=2})
`$objectValue = [pscustomobject][ordered]@{schema_version=1;status='PASS'}
`$dictionaryValue = [ordered]@{schema_version=1;status='PASS'}
`$scalarValue = 'PASS'
Write-JsonDurable -Path (Join-Path `$probeDirectory 'empty_array.json') -Value `$empty
Write-JsonDurable -Path (Join-Path `$probeDirectory 'singleton.json') -Value `$singleton
Write-JsonDurable -Path (Join-Path `$probeDirectory 'multiple.json') -Value `$multiple
Write-JsonDurable -Path (Join-Path `$probeDirectory 'object.json') -Value `$objectValue
Write-JsonDurable -Path (Join-Path `$probeDirectory 'dictionary.json') -Value `$dictionaryValue
Write-JsonDurable -Path (Join-Path `$probeDirectory 'scalar.json') -Value `$scalarValue
"@
  & ([scriptblock]::Create($probeScript))
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($name in @('empty_array.json','singleton.json','multiple.json',
      'object.json','dictionary.json','scalar.json')) {
    [string]$path = Join-Path $Directory $name
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($path)
    [string]$text = [System.Text.Encoding]::UTF8.GetString($bytes)
    [bool]$parseValid = $false
    [object]$parsed = $null
    try {
      $parsed = $text | ConvertFrom-Json -ErrorAction Stop
      $parseValid = $true
    } catch {
      $parseValid = $false
    }
    $rows.Add([pscustomobject][ordered]@{
      file=$name;size_bytes=[long]$bytes.Length
      hex=(($bytes | ForEach-Object {$_.ToString('X2')}) -join '')
      sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
      utf8_bom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
      trailing_crlf=($bytes.Length -ge 2 -and
        $bytes[$bytes.Length - 2] -eq 0x0D -and
        $bytes[$bytes.Length - 1] -eq 0x0A)
      json_parse_valid=$parseValid
      root_array=$text.TrimStart().StartsWith('[')
      parsed_count=[long]@($parsed).Count
    })
  }
  return [pscustomobject][ordered]@{
    runner_helpers_executed=$true;files=$rows.ToArray()
  }
}

$legacyTools = @(
  [ordered]@{
    path = 'tools/run_dual_diag_continuous_hil.ps1'
    sha256 = '92001BFEFEC64C96886AF76AEF1D8B9470C6ECC504A3713614857D64961DBD9D'
    limitation = 'PARAM_REQUEST_READ #20 single-value runner; explicitly not a full PARAM_VALUE list proof'
  },
  [ordered]@{
    path = 'tools/hil_capture_serial.ps1'
    sha256 = '3E7633E305FB253C15735A9B11479ED0A7BF2B8E0397D2E2EE81828D8BF7BC59'
    limitation = 'single-port generic capture has no dual-port power-cycle, #21 fixture, 932-frame, heartbeat, or diagnostic-state gate'
  },
  [ordered]@{
    path = 'tools/hil_analyze_param_proxy_capture.py'
    sha256 = '989B6A0EA0C270F020C82F4BA46533DC21461C48CE24F9801626A407018D4B1E'
    limitation = 'analyzer alone does not make source/count/footer/exit status a complete #21 HIL acceptance gate'
  }
)
foreach ($legacy in $legacyTools) {
  $fullLegacyPath = Join-Path $repo ([string]$legacy.path)
  $exists = Test-Path -LiteralPath $fullLegacyPath -PathType Leaf
  $actualHash = if ($exists) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $fullLegacyPath).Hash
  } else {
    ''
  }
  $legacy.actual_sha256 = $actualHash
  $legacy.hash_matches = ($actualHash -eq [string]$legacy.sha256)
}

$RunnerPath = [System.IO.Path]::GetFullPath($RunnerPath)
$runnerExists = Test-Path -LiteralPath $RunnerPath -PathType Leaf
Add-Check -Name 'dedicated_runner_exists' -Passed $runnerExists `
    -Detail 'Dedicated #21/932 dual-diagnostic runner must exist.'

if ($runnerExists) {
  Assert-NoReparsePointInPath -Path $RunnerPath -Label 'RUNNER'
  $runnerBoundStream = New-Object System.IO.FileStream($RunnerPath,
      [System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read)
  Assert-NoReparsePointInPath -Path $RunnerPath -Label 'RUNNER'
  $runnerFinalHandlePath = Get-NormalizedFinalHandlePath `
      -Stream $runnerBoundStream
  if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath($RunnerPath),
        [System.IO.Path]::GetFullPath($runnerFinalHandlePath),
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ('RUNNER_FINAL_HANDLE_PATH_MISMATCH requested={0} final={1}' -f
      $RunnerPath, $runnerFinalHandlePath)
  }
  $runnerBoundBytes = Get-BoundStreamBytes -Stream $runnerBoundStream
  $runnerInitialSha256 = Get-BytesSha256 -Bytes $runnerBoundBytes
  $runnerInitialSize = [long]$runnerBoundBytes.LongLength
  $runnerWriteOpenDenied = Test-WriteOpenDeniedByBinding -Path $RunnerPath
  Write-BytesDurable -Path (Join-Path $EvidenceDirectory `
      'bound_runner_source.ps1') -Bytes $runnerBoundBytes
  [string]$source = $utf8Strict.GetString($runnerBoundBytes)
  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput(
      $source, $RunnerPath, [ref]$tokens, [ref]$parseErrors)
  Add-Check -Name 'powershell_ast_parse' -Passed ($parseErrors.Count -eq 0) `
      -Detail ('parse_error_count=' + $parseErrors.Count)
  $ifCommandAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    [string]$node.GetCommandName() -ceq 'if'
  }, $true))
  Add-Check -Name 'powershell_if_keyword_never_parsed_as_command' `
      -Passed ($ifCommandAsts.Count -eq 0) `
      -Detail ('CommandAst_if_count=' + $ifCommandAsts.Count +
        ' extents=' + (@($ifCommandAsts | ForEach-Object {
          $_.Extent.StartLineNumber.ToString() + ':' +
          $_.Extent.StartColumnNumber.ToString()
        }) -join ','))
  [string]$runnerDiskStartSha = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $RunnerPath).Hash
  [long]$runnerDiskStartSize = (Get-Item -LiteralPath $RunnerPath).Length
  Add-Check -Name 'runner_bound_source_start_exact' `
      -Passed ($runnerDiskStartSha -ceq $runnerInitialSha256 -and
        $runnerDiskStartSize -eq $runnerInitialSize) `
      -Detail ('bound_sha=' + $runnerInitialSha256 + ' disk_sha=' +
        $runnerDiskStartSha + ' size=' + $runnerDiskStartSize)
  Add-Check -Name 'runner_source_write_open_denied_while_bound' `
      -Passed $runnerWriteOpenDenied `
      -Detail 'Runner source is held FileShare.Read through all child scenarios and final seal.'
  Add-Check -Name 'runner_source_reparse_free_final_handle_exact' `
      -Passed ([string]::Equals(
        [System.IO.Path]::GetFullPath($RunnerPath),
        [System.IO.Path]::GetFullPath($runnerFinalHandlePath),
        [System.StringComparison]::OrdinalIgnoreCase)) `
      -Detail ('requested=' + $RunnerPath + ' final=' +
        $runnerFinalHandlePath + ' all_components_checked_pre_post=true')
  [string]$runnerReparseCallText =
      "Assert-NoReparsePointInPath -Path `$RunnerPath -Label 'RUNNER'"
  [int]$runnerReparsePreOffset = $checkerSource.IndexOf(
      $runnerReparseCallText, [System.StringComparison]::Ordinal)
  [int]$runnerOpenOffset = $checkerSource.IndexOf(
      '$runnerBoundStream = New-Object System.IO.FileStream($RunnerPath',
      [System.StringComparison]::Ordinal)
  [int]$runnerReparsePostOffset = if ($runnerReparsePreOffset -ge 0) {
    $checkerSource.IndexOf($runnerReparseCallText,
      $runnerReparsePreOffset + $runnerReparseCallText.Length,
      [System.StringComparison]::Ordinal)
  } else { -1 }
  [int]$runnerFinalPathOffset = $checkerSource.IndexOf(
      '$runnerFinalHandlePath = Get-NormalizedFinalHandlePath',
      [System.StringComparison]::Ordinal)
  [int]$runnerBoundBytesOffset = $checkerSource.IndexOf(
      '$runnerBoundBytes = Get-BoundStreamBytes -Stream $runnerBoundStream',
      [System.StringComparison]::Ordinal)
  [int]$runnerChildLoopOffset = $checkerSource.LastIndexOf(
      '$childRuns = New-Object ''System.Collections.Generic.List[object]''',
      [System.StringComparison]::Ordinal)
  Add-Check -Name 'runner_reparse_pre_post_handle_checks_precede_hash_and_children' `
      -Passed ($runnerReparsePreOffset -ge 0 -and
        $runnerOpenOffset -gt $runnerReparsePreOffset -and
        $runnerReparsePostOffset -gt $runnerOpenOffset -and
        $runnerFinalPathOffset -gt $runnerReparsePostOffset -and
        $runnerBoundBytesOffset -gt $runnerFinalPathOffset -and
        $runnerChildLoopOffset -gt $runnerBoundBytesOffset -and
        [regex]::Matches($checkerSource,
          [regex]::Escape($runnerReparseCallText)).Count -eq 2) `
      -Detail ('pre=' + $runnerReparsePreOffset + ' open=' +
        $runnerOpenOffset + ' post=' + $runnerReparsePostOffset +
        ' final=' + $runnerFinalPathOffset + ' bytes=' +
        $runnerBoundBytesOffset + ' child=' + $runnerChildLoopOffset)
  $genericListProbeRows = New-Object `
      'System.Collections.Generic.List[object]'
  [bool]$genericListProbePassed = $true
  foreach ($probeCount in @(0, 1, 2)) {
    $genericList = New-Object 'System.Collections.Generic.List[object]'
    for ($probeIndex = 0; $probeIndex -lt $probeCount; ++$probeIndex) {
      $genericList.Add([pscustomobject][ordered]@{
        index=$probeIndex;value=('event_{0}' -f $probeIndex)
      })
    }
    [bool]$arraySubexpressionThrew = $false
    [string]$arraySubexpressionExceptionType = ''
    [string]$arraySubexpressionException = ''
    try {
      [object[]]$unsafeArray = @($genericList)
      [void]$unsafeArray
    } catch {
      $arraySubexpressionThrew = $true
      $arraySubexpressionExceptionType = $_.Exception.GetType().FullName
      $arraySubexpressionException = $_.Exception.GetType().FullName +
          ': ' + $_.Exception.Message
    }
    [object[]]$safeArray = $genericList.ToArray()
    [bool]$safeCountExact = ($safeArray.Count -eq $probeCount)
    [bool]$expectedPs51Failure = ($PSVersionTable.PSVersion.Major -ne 5 -or
        ($arraySubexpressionThrew -and
         $arraySubexpressionExceptionType -ceq 'System.ArgumentException'))
    if (-not $safeCountExact -or -not $expectedPs51Failure) {
      $genericListProbePassed = $false
    }
    $genericListProbeRows.Add([pscustomobject][ordered]@{
      source_count=$probeCount
      array_subexpression_threw=$arraySubexpressionThrew
      array_subexpression_exception_type=$arraySubexpressionExceptionType
      array_subexpression_exception=$arraySubexpressionException
      to_array_count=$safeArray.Count
      to_array_count_exact=$safeCountExact
    })
  }
  Write-JsonDurable -Path (Join-Path $EvidenceDirectory `
      'ps51_generic_list_probe.json') -Value ([ordered]@{
        schema_version=1
        powershell_version=$PSVersionTable.PSVersion.ToString()
        passed=$genericListProbePassed
        rows=$genericListProbeRows.ToArray()
      })
  Add-Check -Name 'ps51_generic_list_0_1_2_reproduction' `
      -Passed $genericListProbePassed `
      -Detail ('PowerShell=' + $PSVersionTable.PSVersion.ToString() +
        '; Generic.List[object] array-subexpression is unsafe on PS5.1, ' +
        'while ToArray preserves exact 0/1/2 cardinality.')
  $jsonProbeDirectory = Join-Path $EvidenceDirectory `
      'runner_json_serialization_probe'
  $jsonProbe = Invoke-RunnerJsonSerializationProbe -RunnerAst $ast `
      -Directory $jsonProbeDirectory
  Write-JsonDurable -Path (Join-Path $jsonProbeDirectory `
      'probe_summary.json') -Value $jsonProbe
  $emptyProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'empty_array.json' })[0]
  $singletonProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'singleton.json' })[0]
  $multipleProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'multiple.json' })[0]
  $objectProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'object.json' })[0]
  $dictionaryProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'dictionary.json' })[0]
  $scalarProbe = @($jsonProbe.files | Where-Object {
      $_.file -eq 'scalar.json' })[0]
  Add-Check -Name 'durable_empty_json_array_exact' `
      -Passed ($emptyProbe.size_bytes -eq 4 -and
        $emptyProbe.hex -ceq '5B5D0D0A' -and
        $emptyProbe.sha256 -ceq
          'A5338D955B09046EC0B16F3A9625B7955C763AAE07DC722E474E6078745F932F' -and
        $emptyProbe.json_parse_valid -and $emptyProbe.root_array -and
        $emptyProbe.parsed_count -eq 0) `
      -Detail ('empty size=' + $emptyProbe.size_bytes + ' hex=' +
        $emptyProbe.hex + ' sha=' + $emptyProbe.sha256 +
        '; expected canonical [] plus CRLF')
  Add-Check -Name 'durable_json_utf8_no_bom_crlf' `
      -Passed (-not $emptyProbe.utf8_bom -and $emptyProbe.trailing_crlf -and
        -not $singletonProbe.utf8_bom -and
        $singletonProbe.trailing_crlf -and -not $multipleProbe.utf8_bom -and
        $multipleProbe.trailing_crlf -and -not $objectProbe.utf8_bom -and
        $objectProbe.trailing_crlf -and -not $dictionaryProbe.utf8_bom -and
        $dictionaryProbe.trailing_crlf -and -not $scalarProbe.utf8_bom -and
        $scalarProbe.trailing_crlf) `
      -Detail 'All durable JSON probe files must be UTF-8 without BOM and end in one CRLF.'
  Add-Check -Name 'durable_json_array_cardinality_preserved' `
      -Passed ($singletonProbe.sha256 -ceq
          '571D45902182A6795A0AACC05975EBEF7E1BCAF0B941E948B6F66C0FF89C5CF3' -and
        $multipleProbe.sha256 -ceq
          'B7A920259B711710D604758872473EA9E08941473217AF3C3FD011FA243D3AAB' -and
        $singletonProbe.json_parse_valid -and $singletonProbe.root_array -and
        $singletonProbe.parsed_count -eq 1 -and
        $multipleProbe.json_parse_valid -and $multipleProbe.root_array -and
        $multipleProbe.parsed_count -eq 2) `
      -Detail ('singleton root_array=' + $singletonProbe.root_array +
        ' count=' + $singletonProbe.parsed_count + ' sha=' +
        $singletonProbe.sha256 + '; multiple root_array=' +
        $multipleProbe.root_array + ' count=' + $multipleProbe.parsed_count +
        ' sha=' + $multipleProbe.sha256)
  Add-Check -Name 'durable_json_nonarray_bytes_unchanged' `
      -Passed ($objectProbe.sha256 -ceq
          '04C86103A8B857B17F30B1124FD78843B654C12746367D1635F5002D6096C63A' -and
        $dictionaryProbe.sha256 -ceq
          '04C86103A8B857B17F30B1124FD78843B654C12746367D1635F5002D6096C63A' -and
        $scalarProbe.sha256 -ceq
          'DF85F2951CF8505298F6B51B6C01942AFBA9C8CD90DB4F5CF615B37041F4D02C' -and
        $objectProbe.json_parse_valid -and $dictionaryProbe.json_parse_valid -and
        $scalarProbe.json_parse_valid -and -not $objectProbe.root_array -and
        -not $dictionaryProbe.root_array -and -not $scalarProbe.root_array) `
      -Detail ('object=' + $objectProbe.sha256 + ' dictionary=' +
        $dictionaryProbe.sha256 + ' scalar=' + $scalarProbe.sha256)
  $runnerJsonFunction = Get-FunctionText -Ast $ast -Name 'Write-JsonDurable'
  Add-Check -Name 'durable_json_array_branch_scoped' `
      -Passed ($runnerJsonFunction -match
          'Value\s+-is\s+\[Array\][\s\S]*Count\s+-eq\s+0[\s\S]*''\[\]''' -and
        $runnerJsonFunction -match
          'Value\s+-is\s+\[Array\][\s\S]*ConvertTo-Json\s+-InputObject\s+\$Value' -and
        $runnerJsonFunction -match
          '\$Value\s*\|\s*ConvertTo-Json\s+-Depth\s+\$Depth') `
      -Detail 'Array 0/1/N values must remain root arrays; only non-arrays retain pipeline serialization.'
  $runnerJsonlFunction = Get-FunctionText -Ast $ast `
      -Name 'Write-DurableJsonlRecord'
  $jsonlUtf8 = New-Object System.Text.UTF8Encoding($false)
  $jsonlSha256Provider = [System.Security.Cryptography.SHA256]::Create()
  [string]$runnerJsonlSha256 = (($jsonlSha256Provider.ComputeHash(
      $jsonlUtf8.GetBytes($runnerJsonlFunction)) | ForEach-Object {
        $_.ToString('X2')
      }) -join '')
  $jsonlSha256Provider.Dispose()
  Add-Check -Name 'durable_jsonl_helper_unchanged' `
      -Passed ($runnerJsonlSha256 -ceq
        '8B35F7828CA28D1B9EEFC82F120E3FEEE18C7F07225DFF1B3C3CF37B3CCA012C') `
      -Detail ('Write-DurableJsonlRecord source SHA256=' + $runnerJsonlSha256)

  foreach ($forbidden in @('DiscardInBuffer', 'DiscardOutBuffer', 'ReadExisting')) {
    Add-Check -Name ('forbidden_api_absent_' + $forbidden) `
        -Passed (-not $source.Contains($forbidden)) `
        -Detail "Serial evidence must never be discarded via $forbidden."
  }

  Assert-SourcePattern -Name 'default_vehicle_port' `
      -Pattern "\[string\]\`$VehiclePort\s*=\s*'COM3'" `
      -Description 'Vehicle default COM3'
  Assert-SourcePattern -Name 'default_vehicle_baud' `
      -Pattern "\[int\]\`$VehicleBaud\s*=\s*115200" `
      -Description 'Vehicle default 115200'
  Assert-SourcePattern -Name 'default_vehicle_pnp_identity' `
      -Pattern 'USB\\VID_303A&PID_1001&MI_00\\7&7131F6A&0&0000' `
      -Description 'Vehicle COM3 frozen PNP identity'
  Assert-SourcePattern -Name 'default_ground_port' `
      -Pattern "\[string\]\`$GroundPort\s*=\s*'COM6'" `
      -Description 'Ground default COM6'
  Assert-SourcePattern -Name 'default_ground_baud' `
      -Pattern "\[int\]\`$GroundBaud\s*=\s*57600" `
      -Description 'Ground default 57600'
  Assert-SourcePattern -Name 'default_ground_pnp_identity' `
      -Pattern 'USB\\VID_303A&PID_1001&MI_00\\7&2159A644&0&0000' `
      -Description 'Ground COM6 frozen PNP identity'
  Assert-SourcePattern -Name 'timeout_default_7200' `
      -Pattern "\[int\]\`$OverallTimeoutSeconds\s*=\s*7200" `
      -Description 'overall timeout defaults to 7200 seconds'
  Assert-SourcePattern -Name 'stall_default_120' `
      -Pattern "\[int\]\`$StallTimeoutSeconds\s*=\s*120" `
      -Description 'expected-index stall timeout defaults to 120 seconds'
  Assert-SourcePattern -Name 'duplicate_guard_default_30' `
      -Pattern "\[int\]\`$DuplicateGuardSeconds\s*=\s*30" `
      -Description 'post-index-931 duplicate guard defaults to 30 seconds'
  Assert-SourcePattern -Name 'data_plane_readiness_timeout_default_720' `
      -Pattern 'ValidateRange\(30,\s*3600\)[\s\S]{0,120}\$DataPlaneReadinessTimeoutSeconds\s*=\s*720' `
      -Description 'FC data-plane readiness timeout defaults to 720 seconds with a bounded ValidateRange'
  Assert-SourcePattern -Name 'prebaseline_backlog_drain_timeout_default_720' `
      -Pattern 'ValidateRange\(30,\s*3600\)[\s\S]{0,120}\$BacklogDrainTimeoutSeconds\s*=\s*720' `
      -Description 'Cold-boot generic PARAM backlog drain is bounded and defaults to 720 seconds.'
  Assert-SourcePattern -Name 'readiness_B_reserve_covers_write_timeout_margin' `
      -Pattern 'ReadinessVehicleBReserveMs\s*=\s*\[double\]3000\.0[\s\S]{0,160}SnapshotWriteDeadlineMarginMs\s*=\s*\[double\]500\.0' `
      -Description 'B reserve is at least SerialPort WriteTimeout 2000 ms plus an explicit 500 ms margin.'
  Assert-SourcePattern -Name 'readiness_device_ms_explicit_tolerance_100' `
      -Pattern 'ReadinessDeviceMsToleranceMs\s*=\s*\[uint64\]100' `
      -Description 'The 5000 ms A/B device-clock bracket permits only an explicit 100 ms clock/tick tolerance.'
  Assert-SourcePattern -Name 'power_off_minimum_5000ms' `
      -Pattern 'ValidateRange\(5000,\s*60000\)[\s\S]{0,120}\$PowerOffConfirmMs\s*=\s*5000' `
      -Description 'both ports must remain absent continuously for at least five seconds'

  foreach ($literal in @(
      'FD02000063FFBE1500000101D507',
      'FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75',
      'STAT_RUNTIME',
      '535441545F52554E54494D4500000000',
      'BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8')) {
    Add-Check -Name ('required_literal_' + $literal.Substring(0, [Math]::Min(16, $literal.Length))) `
        -Passed $source.Contains($literal) -Detail ("Required frozen literal: $literal")
  }

  foreach ($patternRow in @(
      @('fixture_message_id_21', 'message_id\s*=\s*21'),
      @('fixture_sequence_99', 'sequence\s*=\s*99'),
      @('fixture_source_255_190', 'source_system\s*=\s*255[\s\S]{0,100}source_component\s*=\s*190'),
      @('fixture_target_1_1', 'target_system\s*=\s*1[\s\S]{0,100}target_component\s*=\s*1'),
      @('fixture_crc_extra_159', 'crc_extra\s*=\s*159'),
      @('expected_param_count_932', 'expected_param_count\s*=\s*932'),
      @('expected_last_index_931', 'expected_last_index\s*=\s*931'),
      @('expected_source_1_1', 'expected_source_system\s*=\s*1[\s\S]{0,100}expected_source_component\s*=\s*1'),
      @('heartbeat_limit_2500', 'heartbeat_max_gap_ms\s*=\s*2500'),
      @('canonical_definitions_import', 'Import-MavlinkDefinitions'),
      @('canonical_definition_count', 'definition_count[\s\S]{0,80}80'),
      @('request_write_once', 'Write-ExactRequestOnce'),
      @('causal_gate', 'R0_causal_gate_stop_no_request'),
      @('data_plane_readiness_window_helper',
        'Test-DataPlaneReadinessWindow'),
      @('data_plane_passive_candidate_helper',
        'Test-DataPlanePassiveCandidate'),
      @('data_plane_passive_budget_helper',
        'Get-ReadinessPassiveWindowDecision'),
      @('data_plane_readiness_live_gate',
        'Invoke-DataPlaneReadinessGate'),
      @('absolute_deadline_budget_helper',
        'Get-DeadlineBoundSnapshotBudget'),
      @('snapshot_absolute_deadline',
        'AbsoluteDeadlineElapsedMs'),
      @('readiness_B_reserve_ms',
        'ReadinessVehicleBReserveMs'),
      @('snapshot_write_deadline_margin_ms',
        'SnapshotWriteDeadlineMarginMs'),
      @('deadline_bound_write_plan_helper',
        'Get-DeadlineBoundWritePlan'),
      @('vehicle_partial_usb_wake_helper',
        'Get-VehiclePartialUsbWakeDecision'),
      @('vehicle_partial_usb_wake_stall_ms',
        'VehiclePartialUsbWakeStallMs'),
      @('vehicle_partial_usb_wake_minimum_remaining_ms',
        'VehiclePartialUsbWakeMinimumRemainingMs'),
      @('vehicle_partial_usb_wake_write_timeout_ms',
        'VehiclePartialUsbWakeWriteTimeoutMs'),
      @('readiness_snapshot_response_helper',
        'Test-ReadinessSnapshotResponse'),
      @('readiness_last_snapshot_selector',
        'Select-ReadinessLastVehicleSnapshot'),
      @('capture_matcher_snapshot_helper',
        'Get-CaptureMatcherSnapshot'),
      @('sync_invalid_suppressed_snapshot_helper',
        'New-SyncInvalidSuppressedSnapshot'),
      @('post_diagnostic_plan_helper',
        'Get-PostDiagnosticPlan'),
      @('baseline_attempt_disposition_helper',
        'Get-BaselineAttemptDisposition'),
      @('official_baseline_gate_helper',
        'Invoke-OfficialBaselineGate'),
      @('pre_request_recovery_pair_promotion_helper',
        'Test-PreRequestRecoveryBacklogPairPromotion'),
      @('request_suppressed_post_assessment_helper',
        'New-RequestSuppressedPostAssessment'),
      @('param_event_copy_before_reset_helper',
        'Copy-ParamListEventsToEvidence'),
      @('readiness_parser_epoch_close_helper',
        'Complete-ReadinessParserEpoch'),
      @('readiness_matcher_clean_helper',
        'Test-CaptureMatcherClean'),
      @('readiness_expected_A_seed_helper',
        'Get-ReadinessExpectedA'),
      @('readiness_pump_to_idle_helper',
        'Invoke-PumpPairUntilIdle'),
      @('sync_invalid_continuation_evidence_helper',
        'New-SyncInvalidContinuationEvidence'),
      @('exception_safe_backlog_projection_helper',
        'Get-BacklogDrainEvidenceProjection'),
      @('primary_finalization_failure_resolution_helper',
        'Resolve-FinalizationFailure'),
      @('raw_evidence_fallback_projection_helper',
        'Get-RawEvidenceFallbackProjection'),
      @('pump_fairness_fallback_projection_helper',
        'Get-PumpFairnessFallbackProjection'),
      @('readiness_sync_invalid_latch_helper',
        'New-ReadinessSyncInvalidLatch'),
      @('readiness_snapshot_transition_helper',
        'Get-ReadinessSnapshotTransition'),
      @('readiness_device_ms_tolerance',
        'ReadinessDeviceMsToleranceMs'),
      @('data_plane_readiness_timeout_setup_invalid',
        'data-plane readiness timeout; request suppressed'),
      @('data_plane_readiness_evidence',
        'data_plane_readiness\.json'),
      @('data_plane_readiness_schema',
        'schema_version\s*=\s*1[\s\S]{0,300}valid[\s\S]{0,160}timed_out[\s\S]{0,300}gate_started_elapsed_ms[\s\S]{0,500}windows'),
      @('strict_ascending', 'strict_ascending'),
      @('same_boot_gate', 'same_boot'),
      @('ground_query', 'VCGSTAT\?`n'),
      @('vehicle_query', 'VCSTAT\?`n'),
      @('write_through', 'FileOptions\]::WriteThrough'),
      @('flush_to_disk', 'Flush\(\$true\)'),
      @('postclose_error', 'postclose_finalization_error\.json'),
      @('primary_error_finalization_regression',
        'finalization_primary_error_regression\.json'),
      @('artifact_hashes', 'artifact_hashes\.json'),
      @('live_progress_jsonl', 'live_progress\.jsonl'),
      @('progress_exact_format', 'PROGRESS indexed=\{0\}/932 last=\{1\} elapsed_s=\{2:F1\} hb_max_ms=\{3:F1\} stall_s=\{4:F1\}'),
      @('progress_30_seconds', 'last_elapsed_seconds\)\s+-ge\s+30\.0'),
      @('progress_25_indices', 'last_indexed\)\s+-ge\s+25'),
      @('live_progress_flush_each_record', 'Write-DurableJsonlRecord[\s\S]{0,500}Flush\(\$true\)'),
      @('preopen_timeout_scenario', "'POWER_OFF_TIMEOUT'"),
      @('evidence_stream_seal_helper', 'Seal-EvidenceStreamsBeforeRawHash'),
      @('live_progress_append_reopen', 'Open-DurableJsonlAppendStream'),
      @('identity_inventory_allows_empty',
        'AllowEmptyCollection\(\)[\s\S]{0,80}\[object\[\]\]\$Inventory'),
      @('offline_wait_reappear_sequence',
        'Test-BoundInventoryPollSequence'),
      @('shared_pre_power_decision', 'Get-PrePowerIdentityDecision'),
      @('final_console_status', 'FINAL \{0\} output=\{1\}'),
      @('overwrite_refusal', 'refusing overwrite'),
      @('exit_pass', "status\s+-eq\s+'PASS'[\s\S]{0,100}0"),
      @('exit_error', "status\s+-eq\s+'ERROR'[\s\S]{0,100}2"))) {
    Assert-SourcePattern -Name ([string]($patternRow[0])) `
        -Pattern ([string]($patternRow[1])) `
        -Description ('Required live/offline contract: ' +
          [string]($patternRow[0]))
  }

  foreach ($liveEvent in @('runner_started',
      'power_off_confirmed_waiting_for_ports', 'ports_reappeared',
      'ports_opened', 'data_plane_readiness_started',
      'data_plane_readiness_progress', 'data_plane_readiness_window',
      'data_plane_readiness_result',
      'baseline_complete', 'setup_invalid', 'request_sent',
      'progress', 'list_complete', 'duplicate_guard_complete',
      'post_snapshots', 'footer_fsynced', 'final_status', 'error')) {
    Add-Check -Name ('live_progress_event_' + $liveEvent) `
        -Passed $source.Contains("'$liveEvent'") `
        -Detail "Required durable lifecycle event: $liveEvent"
  }

  $topLevelStatements = @($ast.EndBlock.Statements)
  $brokerGateAst = @($topLevelStatements | Where-Object {
      $_ -is [System.Management.Automation.Language.IfStatementAst] -and
      $_.Extent.Text -match '^\s*if\s*\(\$ReaderBrokerMode\)'
    })
  $selfGateAst = @($topLevelStatements | Where-Object {
      $_ -is [System.Management.Automation.Language.IfStatementAst] -and
      $_.Extent.Text -match '^\s*if\s*\(\$SelfTest\)'
    })
  [int]$selfGate = if ($selfGateAst.Count -eq 1) {
    [int]$selfGateAst[0].Extent.StartOffset
  } else { -1 }
  [int]$brokerGate = if ($brokerGateAst.Count -eq 1) {
    [int]$brokerGateAst[0].Extent.StartOffset
  } else { -1 }
  $topLevelLiveComStatements = @($topLevelStatements | Where-Object {
      -not ($_ -is
        [System.Management.Automation.Language.FunctionDefinitionAst]) -and
      $_ -ne $brokerGateAst[0] -and $_ -ne $selfGateAst[0] -and
      $_.Extent.Text -match
        '(Get-LivePortInventory|Wait-ForBothPortsAbsent|Wait-ForBoundPortIdentities|Start-ReaderBrokerClient|New-ConfiguredSerialPort|\.Open\(\))'
    } | Sort-Object {$_.Extent.StartOffset})
  [int]$firstComToken = if ($topLevelLiveComStatements.Count -gt 0) {
    [int]$topLevelLiveComStatements[0].Extent.StartOffset
  } else { $source.Length }
  Add-Check -Name 'selftest_gate_before_any_com_token' `
      -Passed ($brokerGateAst.Count -eq 1 -and
        $selfGateAst.Count -eq 1 -and $brokerGate -lt $selfGate -and
        $selfGate -lt $firstComToken -and
        $brokerGateAst[0].Extent.Text -match
          'Invoke-ReaderBrokerMode[\s\S]{0,120}exit' -and
        $selfGateAst[0].Extent.Text -match
          'Invoke-OfflineSelfTest[\s\S]{0,300}(?:return|exit\s+[012])') `
      -Detail "broker_gate=$brokerGate selftest_gate=$selfGate first_live_com_statement=$firstComToken"
  [string]$gateTail = if ($selfGate -ge 0) {
    $source.Substring($selfGate, [Math]::Min(400, $source.Length - $selfGate))
  } else { '' }
  Add-Check -Name 'selftest_gate_explicit_return_or_exit' `
      -Passed ($gateTail -match 'Invoke-OfflineSelfTest[\s\S]{0,300}(?:return|exit\s+[012])') `
      -Detail 'SelfTest branch must explicitly terminate before live code.'

  $openCalls = [regex]::Matches($source, '(?m)^\s*\$(?:vehicle|ground)Serial\.Open\(\)\s*$').Count
  Add-Check -Name 'exactly_two_explicit_open_calls' -Passed ($openCalls -eq 2) `
      -Detail "open_call_count=$openCalls"
  Assert-SourcePattern -Name 'vehicle_dtr_rts_false' `
      -Pattern '\$vehicleSerial\.DtrEnable\s*=\s*\$false[\s\S]{0,160}\$vehicleSerial\.RtsEnable\s*=\s*\$false' `
      -Description 'Vehicle DTR and RTS disabled before open'
  Assert-SourcePattern -Name 'ground_dtr_rts_false' `
      -Pattern '\$groundSerial\.DtrEnable\s*=\s*\$false[\s\S]{0,160}\$groundSerial\.RtsEnable\s*=\s*\$false' `
      -Description 'Ground DTR and RTS disabled before open'

  $fixtureFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-ExactRequestFixture'
  $listFunction = Get-FunctionText -Ast $ast `
      -Name 'Complete-ParamListAssessment'
  $paramFunction = Get-FunctionText -Ast $ast -Name 'Add-ParamValuePayload'
  $paramStateFunction = Get-FunctionText -Ast $ast -Name 'New-ParamListState'
  $paramAnomalyFunction = Get-FunctionText -Ast $ast `
      -Name 'Register-ParamListAnomaly'
  $paramEventFunction = Get-FunctionText -Ast $ast `
      -Name 'Add-ParamListEventEvidence'
  $preRequestBacklogFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-PreRequestBacklogGate'
  $paramDiagnosticFunction = Get-FunctionText -Ast $ast `
      -Name 'New-ParamListDiagnosticEvidence'
  $proxyTerminalFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-ProxyTerminalClassification'
  $postFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-PostSnapshotContract'
  $vcstat3UInt64Function = Get-FunctionText -Ast $ast `
      -Name 'Get-VehicleVcstat3UInt64'
  $vcstat3StringFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-VehicleVcstat3String'
  $heartbeatGrantDiagnosticFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-VehicleHeartbeatGrantDiagnosticContract'
  $groundDiscardContinuityFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-GroundOrderedDiscardContinuity'
  $baselineFunction = Get-FunctionText -Ast $ast -Name 'Test-BaselineSetup'
  $baselineDispositionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-BaselineAttemptDisposition'
  $officialBaselineGateFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-OfficialBaselineGate'
  $backlogObservationFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-BacklogDrainObservation'
  $backlogStableFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-BacklogDrainStablePair'
  $backlogDrainFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-PreBaselineBacklogDrainGate'
  $liveProgressFunction = Get-FunctionText -Ast $ast `
      -Name 'Add-LiveProgressRecord'
  $backlogRecoveryDispositionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-BacklogSnapshotRecoveryDisposition'
  $backlogRecoveryContinuityFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-BacklogRecoveredSnapshotContinuity'
  $backlogSnapshotRecoveryFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-BacklogSnapshotWithRecovery'
  $preRequestVehicleFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-PreRequestVehicleGate'
  $preRequestDispositionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-PreRequestAttemptDisposition'
  $preM0TailRaceFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-ExactPreM0TailStatRuntimeRace'
  $observedPartialRaceFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-ExactObservedM0StatRuntimePartialD7Race'
  $postM0SnapshotRaceFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-ExactPostM0VehicleSnapshotStatRuntimePartialD7Race'
  $postM0SnapshotRaceDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq
            'Test-ExactPostM0VehicleSnapshotStatRuntimePartialD7Race'
    }, $true))
  $isolatedD7RaceFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-IsolatedPartialD7SnapshotRaceContract'
  $isolatedD7RaceDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq 'Test-IsolatedPartialD7SnapshotRaceContract'
    }, $true))
  $obsoleteIsolatedD7DirectRecheckDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq 'Test-IsolatedPartialD7RecheckContract'
    }, $true))
  $officialPreRequestGateFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-OfficialPreRequestGate'
  $preRequestRecoveryPromotionFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-PreRequestRecoveryBacklogPairPromotion'
  $requestSuppressedPostFunction = Get-FunctionText -Ast $ast `
      -Name 'New-RequestSuppressedPostAssessment'
  $readinessWindowFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-DataPlaneReadinessWindow'
  $readinessGateFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-DataPlaneReadinessGate'
  $readinessGateDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq 'Invoke-DataPlaneReadinessGate'
    }, $true))
  Add-Check -Name 'exactly_one_actual_readiness_gate_function' `
      -Passed ($readinessGateDefinitions.Count -eq 1 -and
        -not $source.Contains('Invoke-DataPlaneReadinessGateLegacy')) `
      -Detail ('actual_count=' + $readinessGateDefinitions.Count +
        '; legacy_token_present=' +
        $source.Contains('Invoke-DataPlaneReadinessGateLegacy'))
  $readinessDecisionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-DataPlaneReadinessWindowDecision'
  $snapshotQueryFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-SnapshotQuery'
  $captureIntervalFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-CaptureInterval'
  $deadlineBudgetFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-DeadlineBoundSnapshotBudget'
  $deadlineWriteFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-DeadlineBoundWritePlan'
  $vehiclePartialUsbWakeFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-VehiclePartialUsbWakeDecision'
  $readinessResponseFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-ReadinessSnapshotResponse'
  $readinessLastSnapshotFunction = Get-FunctionText -Ast $ast `
      -Name 'Select-ReadinessLastVehicleSnapshot'
  $passiveCandidateFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-DataPlanePassiveCandidate'
  $passiveDecisionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-ReadinessPassiveWindowDecision'
  $matcherSnapshotFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-CaptureMatcherSnapshot'
  $suppressedSnapshotFunction = Get-FunctionText -Ast $ast `
      -Name 'New-SyncInvalidSuppressedSnapshot'
  $postDiagnosticPlanFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-PostDiagnosticPlan'
  $syncInvalidMatcherFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-SyncInvalidMatcherAtLatch'
  $paramEventCopyFunction = Get-FunctionText -Ast $ast `
      -Name 'Copy-ParamListEventsToEvidence'
  $parserEpochFunction = Get-FunctionText -Ast $ast `
      -Name 'Complete-ReadinessParserEpoch'
  $checkedParserEpochFunction = Get-FunctionText -Ast $ast `
      -Name 'Complete-ReadinessParserEpochChecked'
  $matcherCleanFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-CaptureMatcherClean'
  $expectedAFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-ReadinessExpectedA'
  $pumpToIdleFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-PumpPairUntilIdle'
  $serialReadSliceFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-SerialReadSliceSize'
  $serialReadFunction = Get-FunctionText -Ast $ast `
      -Name 'Read-SerialAvailable'
  $pumpPairFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-PumpPair'
  $readinessRawFsyncAgeFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-ReadinessRawFsyncAgeDecision'
  $readinessRawFsyncBoundaryFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-ReadinessRawFsyncBoundary'
  $pumpFairnessStartFunction = Get-FunctionText -Ast $ast `
      -Name 'Start-PumpFairnessService'
  $pumpFairnessCompleteFunction = Get-FunctionText -Ast $ast `
      -Name 'Complete-PumpFairnessService'
  $pumpFairnessEvidenceFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-PumpFairnessEvidence'
  $pumpFairnessClockAnchorFunction = Get-FunctionText -Ast $ast `
      -Name 'New-PumpFairnessStateFromReaderClockAnchor'
  $pumpFairnessTraceFunction = Get-FunctionText -Ast $ast `
      -Name 'Add-PumpFairnessViolation'
  $pumpHotPathPrewarmFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-PumpHotPathPrewarm'
  $readerWorkerTypeFunction = Get-FunctionText -Ast $ast `
      -Name 'Initialize-DualPortReaderWorkerType'
  $readerBarrierDrainFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-ReaderBarrierDrain'
  $readerClockAnchorFunction = Get-FunctionText -Ast $ast `
      -Name 'New-ReaderClockAnchor'
  $readerShutdownFunction = Get-FunctionText -Ast $ast `
      -Name 'Stop-DualPortReaderWorkerAndDrain'
  $readerBrokerModeFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-ReaderBrokerMode'
  $readerBrokerStartFunction = Get-FunctionText -Ast $ast `
      -Name 'Start-ReaderBrokerClient'
  $readerBrokerStopFunction = Get-FunctionText -Ast $ast `
      -Name 'Stop-ReaderBrokerAndDrain'
  $readerBrokerCloseFunction = Get-FunctionText -Ast $ast `
      -Name 'Close-ReaderBrokerAfterFooter'
  $readerBrokerHarnessFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-ReaderBrokerOfflineHarness'
  $exactRequestFunction = Get-FunctionText -Ast $ast `
      -Name 'Write-ExactRequestOnce'
  $captureBytesFunction = Get-FunctionText -Ast $ast `
      -Name 'Add-CaptureBytes'
  $readinessAdministrativeStateFunction = Get-FunctionText -Ast $ast `
      -Name 'New-ReadinessAdministrativeState'
  $readinessCheckpointBoundFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-MaxReadinessPumpCheckpointCount'
  $readinessPumpCheckpointFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-ReadinessPumpCheckpoint'
  $syncContinuationFunction = Get-FunctionText -Ast $ast `
      -Name 'New-SyncInvalidContinuationEvidence'
  $syncInvalidLatchFunction = Get-FunctionText -Ast $ast `
      -Name 'New-ReadinessSyncInvalidLatch'
  $snapshotTransitionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-ReadinessSnapshotTransition'
  $correlatedRowsFunction = Get-FunctionText -Ast $ast `
      -Name 'Select-CorrelatedReportFromRows'
  $correlatedStateFunction = Get-FunctionText -Ast $ast `
      -Name 'Select-CorrelatedReport'
  $m0GateFunction = Get-FunctionText -Ast $ast -Name 'Test-M0CausalGate'
  $integrityFunction = Get-FunctionText -Ast $ast -Name 'Get-ParserIntegrity'
  $identityFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-RoleIdentityBinding'
  $pollSequenceFunction = Get-FunctionText -Ast $ast `
      -Name 'Test-BoundInventoryPollSequence'
  $liveBoundWaitFunction = Get-FunctionText -Ast $ast `
      -Name 'Wait-ForBoundPortIdentities'
  $prePowerDecisionFunction = Get-FunctionText -Ast $ast `
      -Name 'Get-PrePowerIdentityDecision'
  $preM0TailRaceDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq 'Test-ExactPreM0TailStatRuntimeRace'
    }, $true))
  Add-Check -Name 'exactly_one_exact_pre_m0_tail_stat_runtime_race_function' `
      -Passed ($preM0TailRaceDefinitions.Count -eq 1) `
      -Detail ('definition_count=' + $preM0TailRaceDefinitions.Count)
  $observedPartialRaceDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq 'Test-ExactObservedM0StatRuntimePartialD7Race'
    }, $true))
  Add-Check `
      -Name 'exactly_one_exact_observed_m0_stat_runtime_partial_d7_function' `
      -Passed ($observedPartialRaceDefinitions.Count -eq 1) `
      -Detail ('definition_count=' + $observedPartialRaceDefinitions.Count)
  Add-Check `
      -Name 'exactly_one_exact_post_m0_vehicle_snapshot_stat_runtime_partial_d7_function' `
      -Passed ($postM0SnapshotRaceDefinitions.Count -eq 1) `
      -Detail ('definition_count=' + $postM0SnapshotRaceDefinitions.Count)
  Add-Check -Name 'bound_port_identity_requires_5000ms_continuous_stability' `
      -Passed ($source -match
        '\$script:BoundPortIdentityStableMs\s*=\s*\[int\]5000' -and
        $liveBoundWaitFunction -match
          '(?s)RequiredStableMs.*validSinceMs.*lastBinding\.valid.*continuousStableMs.*-ge.*RequiredStableMs.*found=\$true.*required_stable_ms.*continuous_stable_ms' -and
        $liveBoundWaitFunction -match
          '(?s)else\s*\{\s*\$validSinceMs\s*=\s*\$null\s*\$continuousStableMs\s*=\s*0(?:\.0)?\s*\}') `
      -Detail 'Both exact PNP bindings must remain continuously valid for 5000 ms, with any invalid poll resetting the stability window, before broker COM ownership.'
  Add-Check -Name 'bound_port_identity_stability_offline_model' `
      -Passed ($pollSequenceFunction -match
        '(?s)RequiredConsecutiveValidPolls.*consecutiveValidPolls.*lastBinding\.valid.*consecutiveValidPolls.*-ge.*RequiredConsecutiveValidPolls.*found=\$true.*consecutive_valid_poll_count' -and
        $pollSequenceFunction -match
          '(?s)else\s*\{\s*\$consecutiveValidPolls\s*=\s*0\s*\}') `
      -Detail 'The no-COM poll model proves first-valid suppression, invalid reset, and bounded continuous-valid promotion.'
  Add-Check -Name 'reader_broker_open_start_ioexception_is_not_pipe_eof' `
      -Passed ($source -match
        "ValidateSet\('serial','pressure','overflow','timestamp','barrier','ackloss','openio'\)" -and
        $readerWorkerTypeFunction -match
          '(?s)OPEN_START synthetic IOException.*catch\s*\(IOException\s+error\).*channel\s*!=\s*null.*SendError\(error\).*return\s+orderlyClose\s*\?\s*0\s*:\s*3' -and
        $readerWorkerTypeFunction -match
          '(?s)vehicle\.Open\(\).*OPEN_START vehicle COM open failed' -and
        $readerWorkerTypeFunction -match
          '(?s)ground\.Open\(\).*OPEN_START ground COM open failed') `
      -Detail 'A connected OPEN_START IOException must be returned as an exact role-bearing child ERROR before exit 3, never collapsed into generic pipe EOF.'
  Add-Check -Name 'serial_read_slice_is_bounded_to_32_bytes' `
      -Passed ($source -match
        '\$script:SerialReadSliceBytes\s*=\s*\[int\]32' -and
        $serialReadSliceFunction -match
        'Available[\s\S]*BufferLength[\s\S]*MaximumBytesPerRead[\s\S]*Math\]::Min' -and
        $serialReadFunction.Contains('Get-SerialReadSliceSize')) `
      -Detail 'Each expensive PowerShell capture/parse slice is bounded to 32 bytes before the other COM stream is serviced.'
  Add-Check -Name 'dual_port_pump_fixed_vehicle_then_ground_one_slice_each' `
      -Passed ($source -match
        '\$script:SerialReadSlicesPerTurn\s*=\s*\[int\]1' -and
        $serialReadFunction -match
        '\[int\]\$MaximumReads\s*=\s*\$script:SerialReadSlicesPerTurn' -and
        [regex]::Matches($pumpPairFunction,
          'Read-SerialAvailable\s+-Serial').Count -eq 2 -and
        $pumpPairFunction -match (
          '(?s)\[int\]\$read\s*=\s*0\s*' +
          '\$read\s*\+=\s*Read-SerialAvailable\s+' +
          '-Serial\s+\$VehicleSerial\s+-State\s+\$VehicleState\s*' +
          '\$read\s*\+=\s*Read-SerialAvailable\s+' +
          '-Serial\s+\$GroundSerial\s+-State\s+\$GroundState\s*' +
          'return\s+\$read') -and
        -not $pumpPairFunction.Contains('$script:PumpTurn')) `
      -Detail 'Every pump turn services exactly one bounded Vehicle slice followed by exactly one bounded Ground slice, with no alternating PumpTurn branch.'
  Add-Check -Name 'dual_port_pump_fairness_is_measured_and_sealed' `
      -Passed ($source -match
        '\$script:PumpFairnessHardLimitMs\s*=\s*\[double\]100\.0' -and
        $source -match
        '\$script:PumpFairnessTargetMs\s*=\s*\[double\]75\.0' -and
        $source -match
        '\$script:MaxPumpFairnessViolationEvents\s*=\s*\[int\]64' -and
        $serialReadFunction.Contains('Start-PumpFairnessService') -and
        $serialReadFunction.Contains('Complete-PumpFairnessService') -and
        $serialReadFunction.Contains('-RoleState $fairnessRoleState') -and
        -not $serialReadFunction.Contains('$fairnessToken') -and
        $pumpFairnessStartFunction.Contains('service_active') -and
        $pumpFairnessStartFunction.Contains('reentry') -and
        $pumpFairnessStartFunction.Contains('throw') -and
        -not $pumpFairnessStartFunction.Contains('[pscustomobject]') -and
        $pumpFairnessCompleteFunction.Contains(
          'completion_without_start') -and
        $pumpFairnessStartFunction.Contains(
          'service_gap_over_hard_limit_count') -and
        $pumpFairnessCompleteFunction.Contains(
          'read_parse_duration_over_hard_limit_count') -and
        $pumpFairnessTraceFunction -match
          'kind[\s\S]*started_elapsed_ms[\s\S]*finished_elapsed_ms[\s\S]*duration_ms' -and
        $pumpFairnessTraceFunction -match
          'phase[\s\S]*bytes_read[\s\S]*raw_start_offset[\s\S]*raw_end_offset_exclusive' -and
        $pumpFairnessTraceFunction -match
          'admin_stage[\s\S]*gc0_start[\s\S]*gc0_end[\s\S]*overflow' -and
        $pumpFairnessEvidenceFunction -match
          'schema_version=2[\s\S]*vehicle[\s\S]*ground[\s\S]*valid[\s\S]*violation_event_cap[\s\S]*violation_event_count[\s\S]*violation_event_overflow_count[\s\S]*violation_events' -and
        $pumpHotPathPrewarmFunction.Contains('System.IO.MemoryStream') -and
        $pumpHotPathPrewarmFunction.Contains('New-CaptureState') -and
        $pumpHotPathPrewarmFunction.Contains('Add-CaptureBytes') -and
        $pumpHotPathPrewarmFunction.Contains(
          'Test-DataPlaneReadinessWindow') -and
        $pumpHotPathPrewarmFunction.Contains(
          'New-ReadinessAdministrativeState') -and
        $pumpHotPathPrewarmFunction.Contains('WaitForPendingFinalizers') -and
        -not $pumpHotPathPrewarmFunction.Contains(
          'System.IO.Ports.SerialPort') -and
        -not $pumpHotPathPrewarmFunction.Contains('Write-ExactRequestOnce') -and
        $readinessAdministrativeStateFunction.Length -gt 0 -and
        $source -match
        '\$hotPathPrewarm\s*=\s*Invoke-PumpHotPathPrewarm[\s\S]*\$readerBrokerBundle\s*=\s*Start-ReaderBrokerClient' -and
        $source -match 'hot_path_prewarm\s*=\s*\$hotPathPrewarm' -and
        $source.Contains("'pump_fairness.json'")) `
      -Detail 'Every open-port service uses no-token fail-closed role state; bounded 75 ms causal traces, isolated cold-path prewarm, and sealed evidence preserve the strict 100 ms contract.'
  Add-Check -Name 'dual_port_reader_worker_fixed_ring_contract' `
      -Passed ($source -match
        '\$script:ReaderRingSlotCount\s*=\s*\[int\]32768' -and
        $readerWorkerTypeFunction -match
          'sealed\s+class\s+FixedCaptureRing[\s\S]*CaptureSlot\[\][\s\S]*new\s+CaptureSlot\[capacity\]' -and
        $readerWorkerTypeFunction -match
          'sealed\s+class\s+RoleReader[\s\S]*new\s+Thread\([\s\S]*RoleReaderLoop' -and
        $readerWorkerTypeFunction -match
          'VehicleReader[\s\S]*GroundReader' -and
        $readerWorkerTypeFunction -match
          'OverflowLatched[\s\S]*OverflowCount[\s\S]*return\s+false' -and
        $readerWorkerTypeFunction -match
          'ProducerTimestampTicks[\s\S]*ProducerElapsedMs[\s\S]*Sequence[\s\S]*RawStartOffset' -and
        $readerWorkerTypeFunction -match
          'CaptureBarrier[\s\S]*StopAndJoin[\s\S]*Joined' -and
        $readerWorkerTypeFunction -match
          'durationMs\s*>=\s*hardLimitMs' -and
        $readerWorkerTypeFunction -match
          'MaxServiceGapMs\s*<\s*HardLimitMs' -and
        -not ($readerWorkerTypeFunction -match
          'Queue\s*<\s*CaptureRecord\s*>') -and
        $serialReadFunction.Contains('TryDequeueVehicle') -and
        $serialReadFunction.Contains('TryDequeueGround') -and
        $serialReadFunction.Contains('-ProducerElapsedMs') -and
        $serialReadFunction.Contains('-ProducerSequence') -and
        $serialReadFunction.Contains('-ProducerRawStartOffset') -and
        $captureBytesFunction -match
          'ProducerElapsedMs[\s\S]*ProducerSequence[\s\S]*ProducerRawStartOffset' -and
        $captureBytesFunction -match
          'producer raw offset discontinuity[\s\S]*producer sequence discontinuity' -and
        $readerBarrierDrainFunction.Contains('CaptureBarrier') -and
        $readerBarrierDrainFunction.Contains('sequence_exclusive') -and
        $readerShutdownFunction.Contains('StopAndJoin') -and
        $readerShutdownFunction.Contains('joined') -and
        $readerShutdownFunction.Contains('queue_depth')) `
      -Detail 'An in-process C# worker owns one reader thread and a preallocated non-overwriting ring per role; producer sequence/timestamp/raw offset, overflow failure, barrier drain, and joined shutdown are explicit while the hard bound remains strictly below 100 ms.'
  Add-Check -Name 'out_of_process_reader_broker_contract' `
      -Passed ($source -match '\[switch\]\$ReaderBrokerMode' -and
        $source -match '\$script:ReaderBrokerProtocolVersion\s*=\s*\[int\]2' -and
        $readerBrokerModeFunction.Contains('NamedPipeServerStream') -and
        $readerBrokerModeFunction.Contains('synthetic') -and
        $readerBrokerModeFunction.Contains('SerialPort') -and
        $readerBrokerModeFunction.Contains('broker_owns_both_serial_ports') -and
        $readerBrokerModeFunction.Contains('HELLO') -and
        $readerBrokerModeFunction.Contains('DRAIN_BOTH') -and
        $readerBrokerModeFunction.Contains('STOP_CAPTURE') -and
        $readerBrokerModeFunction.Contains('CLOSE_EXIT') -and
        $readerBrokerStartFunction.Contains('NamedPipeClientStream') -and
        $readerBrokerStartFunction.Contains('Start-Process') -and
        $readerBrokerStartFunction.Contains('-WindowStyle Hidden') -and
        $readerBrokerStartFunction.Contains('runner_sha256') -and
        $readerBrokerStartFunction.Contains('protocol_sequence') -and
        $readerBrokerStartFunction.Contains('bounded_record_count') -and
        $readerBrokerStartFunction.Contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE') -and
        $readerBrokerStartFunction.Contains('AssignProcessToJobObject') -and
        $readerBrokerStartFunction.Contains('context_id') -and
        $readerBrokerStartFunction.Contains('qpc_frequency') -and
        $source -match
          'ReaderBrokerMode[\s\S]{0,600}Invoke-ReaderBrokerMode[\s\S]{0,120}(?:return|exit)' -and
        $readerBrokerStopFunction -match
          'Stop-DualPortReaderWorkerAndDrain[\s\S]*stop_capture_valid' -and
        $readerBrokerCloseFunction -match
          'broker_process_exited[\s\S]*broker_exit_code[\s\S]*lifecycle_valid' -and
        $source -match
          'STOP_CAPTURE[\s\S]{0,2500}capture_footer[\s\S]{0,2500}CLOSE_EXIT' -and
        $source -match
          'reader_broker_harness\.json') `
      -Detail 'The same hash-bound runner hosts a hidden child broker over sequenced bounded NamedPipe RPC; only the broker owns both serial ports/rings and shutdown proves child exit before sealing.'
  Add-Check -Name 'reader_broker_nonblocking_vector_handoff_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'RingPosition[\s\S]*BoundaryTimestampTicks[\s\S]*BoundaryElapsedMs[\s\S]*OldContextId[\s\S]*NewContextId' -and
        $readerWorkerTypeFunction -match
          'ApplyBoundaryIfRequested[\s\S]*oldContextId[\s\S]*CapturePositionInto[\s\S]*pendingPhaseTransition[\s\S]*pendingContextIdTransition[\s\S]*newContextId[\s\S]*BoundaryTimestampTicks[\s\S]*OldContextId\s*=\s*oldContextId[\s\S]*NewContextId\s*=\s*newContextId[\s\S]*barrierAcknowledgedGeneration' -and
        $readerWorkerTypeFunction -match
          'RequestContextTransition[\s\S]*RequestContextIdTransition[\s\S]*RequestBarrierAndWait' -and
        $readerWorkerTypeFunction -match
          'serviceContextId[\s\S]*TryEnqueue[\s\S]*serviceContextId' -and
        -not $readerWorkerTypeFunction.Contains(
          'barrierReleasedGeneration') -and
        -not $readerWorkerTypeFunction.Contains('ReleaseBarrier') -and
        $readerBarrierDrainFunction -match
          'vehicle_boundary_timestamp_ticks[\s\S]*vehicle_old_context_id[\s\S]*vehicle_new_context_id[\s\S]*ground_boundary_timestamp_ticks[\s\S]*ground_old_context_id[\s\S]*ground_new_context_id' -and
        $source -match
          '\$m1Transition\.ground_boundary_elapsed_ms[\s\S]*shared_completion_elapsed_ms') `
      -Detail 'Each role publishes its exact sequence/raw/context boundary and immediately resumes polling; the shared completion remains administrative while official M1 uses the Ground vector-cut boundary.'
  Add-Check -Name 'reader_broker_bounded_violation_wire_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'FairnessViolationEvent[\s\S]*ViolationEventCapacity\s*=\s*64[\s\S]*RecordViolation' -and
        $readerWorkerTypeFunction -match
          'ViolationEventCap[\s\S]*ViolationEventCount[\s\S]*ViolationEventTotalCount[\s\S]*ViolationEventOverflowCount[\s\S]*ViolationEvents' -and
        $readerWorkerTypeFunction -match
          'WriteViolationEvent[\s\S]*ReadViolationEvent[\s\S]*violation snapshot bounds failed' -and
        $readerWorkerTypeFunction -match
          'DecorateSnapshotContextNames[\s\S]*contextMap[\s\S]*Phase[\s\S]*Epoch' -and
        $pumpFairnessEvidenceFunction -match
          'RoleSnapshot\.ViolationEventCap[\s\S]*RoleSnapshot\.ViolationEventCount[\s\S]*RoleSnapshot\.ViolationEventTotalCount[\s\S]*RoleSnapshot\.ViolationEventOverflowCount' -and
        $pumpFairnessEvidenceFunction -match
          'schema_version=4[\s\S]*vehicle\.violation_event_count[\s\S]*ground\.violation_event_count[\s\S]*violation_event_total_count[\s\S]*rootViolationEvents') `
      -Detail 'The protocol carries a fixed 64-event role trace whose totals, overflow and mapped phase/epoch replace the former broker zero placeholders at role and root evidence levels.'
  Add-Check -Name 'reader_broker_authenticated_open_start_contract' `
      -Passed ($readerBrokerModeFunction -match
          'Get-FileHash[\s\S]*\$PSCommandPath[\s\S]*actualSourceSha256[\s\S]*source hash binding failed before port ownership' -and
        $readerWorkerTypeFunction -match
          'AcceptHello[\s\S]*suppliedParentPid[\s\S]*nonce[\s\S]*Process\.GetCurrentProcess\(\)\.Id' -and
        $readerWorkerTypeFunction -match
          'OPEN_START[\s\S]*OpenAndStartCapture[\s\S]*NewSerialPort' -and
        $readerWorkerTypeFunction -match
          'expectedBrokerProcessId[\s\S]*brokerProcessId\s*!=\s*expectedBrokerProcessId[\s\S]*OPEN_START' -and
        $readerBrokerStartFunction -match
          'Start-Process[\s\S]*CreateKillOnCloseJob[\s\S]*AssignProcessToKillOnCloseJob[\s\S]*ReaderBrokerClient\]::Connect') `
      -Detail 'The child recomputes its runner hash, HELLO binds nonce and both PIDs, the private kill-on-close Job is assigned, and only then may OPEN_START construct/open COM.'
  Add-Check -Name 'reader_broker_fixed_bounded_multichunk_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'HeaderBytes\s*=\s*32[\s\S]*MaximumRecordsPerDrain\s*=\s*512[\s\S]*MaximumAggregateRecords' -and
        $readerWorkerTypeFunction -match
          'SendDrain[\s\S]*while\s*\(!finalChunk\)[\s\S]*MaximumRecordsPerDrain' -and
        $readerWorkerTypeFunction -match
          'currentChunkRecordCount\s*>=\s*maximumRecordsPerDrain' -and
        $readerWorkerTypeFunction -match
          'finalEndpointMismatch[\s\S]*prematureNonFinal[\s\S]*!finalChunk\s*&&\s*boundedRecordCount\s*==\s*0' -and
        $readerWorkerTypeFunction -match
          'Sequence[\s\S]*RawStartOffset[\s\S]*ContextId') `
      -Detail 'RPC uses a fixed header and a small per-chunk cap; aggregate backlog may span monotonic nonempty chunks and reaches the exact barrier sequence/offset only on the final chunk.'
  Add-Check -Name 'reader_broker_numeric_context_and_role_io_lock_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'UInt32\s+ContextId[\s\S]*SetCaptureContextId[\s\S]*TransitionCaptureContextId' -and
        $readerWorkerTypeFunction -match
          'Dictionary<UInt32,\s*string\[\]>\s+contextMap' -and
        $readerWorkerTypeFunction -match
          'sealed\s+class\s+SerialBrokerPort[\s\S]*readonly\s+object\s+ioGate[\s\S]*Available[\s\S]*lock\s*\(ioGate\)[\s\S]*Read\([\s\S]*lock\s*\(ioGate\)[\s\S]*Write\([\s\S]*lock\s*\(ioGate\)') `
      -Detail 'The broker hot record carries a numeric context id whose phase/epoch mapping is restored only in the parent, and each role serializes read/write/flush access with its own I/O lock.'
  Add-Check -Name 'reader_broker_exact_write_flush_and_fatal_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'WRITE_EXACT_FIXTURE[\s\S]*exactFixtureAccepted[\s\S]*Sha256Hex[\s\S]*destination\.Write[\s\S]*destination\.Flush[\s\S]*acceptedSha' -and
        $readerWorkerTypeFunction -match
          'exactFixtureAttempted\s*=\s*true[\s\S]{0,400}destination\.Write\([\s\S]{0,200}destination\.Flush\(\)[\s\S]{0,300}exactFixtureAccepted\s*=\s*true' -and
        $readerWorkerTypeFunction -match
          'syntheticScenario\s*==\s*"ackloss"[\s\S]{0,300}response loss after exact fixture commit' -and
        $readerWorkerTypeFunction -match
          'FLUSH_PORT[\s\S]*\.Flush\(\)[\s\S]*FLUSH_PORT' -and
        $readerWorkerTypeFunction -match
          'worker\.HasFatalFailure[\s\S]*DRAIN_BOTH[\s\S]*STOP_CAPTURE[\s\S]*CLOSE_EXIT[\s\S]*fatal/overflow latch permits drain and shutdown only' -and
        $exactRequestFunction -match
          'attempt_count[\s\S]*IN_FLIGHT_UNCERTAIN_NO_RETRY[\s\S]*Methods\[''WriteExactFixture''\][\s\S]*WriteExactFixture[\s\S]*ACK_UNCERTAIN_NO_RETRY' -and
        $readerBrokerHarnessFunction -match
          "Scenario\s+'ackloss'[\s\S]*Write-ExactRequestOnce[\s\S]*childSecondRejected[\s\S]*GroundWriteOperationCount") `
      -Detail 'The frozen fixture has a dedicated exactly-once hash-bound write+flush ACK, ordinary flush reaches the child, and overflow/fatal state rejects every mutating operation while preserving shutdown.'
  Add-Check -Name 'reader_broker_two_stage_close_and_wait_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'CLOSE_EXIT refused inconsistent stopped/drained state[\s\S]*groundPort\.Dispose[\s\S]*groundCloseTicks[\s\S]*vehiclePort\.Dispose[\s\S]*vehicleCloseTicks[\s\S]*CLOSE_EXIT' -and
        $readerWorkerTypeFunction -match
          'LatestCloseReport[\s\S]*GroundCloseSucceeded[\s\S]*VehicleCloseSucceeded' -and
        $readerBrokerStopFunction -match
          'STOP_CAPTURE[\s\S]*Stop-DualPortReaderWorkerAndDrain[\s\S]*stop_capture_valid' -and
        $readerBrokerCloseFunction -match
          'capture_footer_recorded[\s\S]*CloseExit\(\)[\s\S]*WaitForExit\(\$ProcessExitTimeoutMs\)[\s\S]*WaitForExit\(\)[\s\S]*Refresh\(\)[\s\S]*broker_process_exited' -and
        $source -match
          'Close-ReaderBrokerAfterFooter[\s\S]*artifact_hashes\.json') `
      -Detail 'STOP_CAPTURE leaves COM open for the durable footer; CLOSE_EXIT reports both role close QPCs before ACK, then the parent performs parameterless WaitForExit+Refresh before final artifact sealing.'
  Add-Check -Name 'reader_broker_child_hot_transport_and_gc_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'sendHeader\s*=\s*new\s+byte\[BrokerWire\.HeaderBytes\][\s\S]*receiveHeader\s*=\s*new\s+byte\[BrokerWire\.HeaderBytes\]' -and
        $readerWorkerTypeFunction -match
          'SendCaptureRecord\(CaptureRecord\s+record\)[\s\S]*recordSendBuffer[\s\S]*PutInt64[\s\S]*SendCore' -and
        $readerWorkerTypeFunction -match
          'SendCore\(BrokerMessageType\s+type,\s*byte\[\]\s+body,[\s\S]{0,80}int\s+bodyLength\)[\s\S]*sendHeader[\s\S]*stream\.Write' -and
        $readerWorkerTypeFunction -match
          'SendRecord\(CaptureRecord\s+record\)[\s\S]*channel\.SendCaptureRecord\(record\)' -and
        -not $readerWorkerTypeFunction.Contains('EncodeRecord') -and
        $readerWorkerTypeFunction -match
          'TimedReleaseSyntheticBrokerPort[\s\S]*700[\s\S]*BrokerGcDuringActiveReads' -and
        $readerWorkerTypeFunction -match
          'GC\.Collect\(\)[\s\S]*WaitForPendingFinalizers\(\)[\s\S]*GC\.Collect\(\)') `
      -Detail 'The child drain hot path reuses fixed wire buffers without per-record MemoryStream/ToArray/header allocation, while timed active reads and a full child GC remain measured against the strict producer bound.'
  Add-Check -Name 'reader_broker_parent_fixed_queue_and_rpc_deadline_contract' `
      -Passed ($readerWorkerTypeFunction -match
          'sealed\s+class\s+FixedClientRecordQueue[\s\S]*CaptureRecord\[\]\s+slots[\s\S]*HighWater' -and
        -not ($readerWorkerTypeFunction -match 'Queue\s*<\s*CaptureRecord\s*>') -and
        $readerWorkerTypeFunction.Contains('VehicleQueueCapacity') -and
        $readerWorkerTypeFunction.Contains('VehicleQueueHighWater') -and
        $readerWorkerTypeFunction.Contains('GroundQueueCapacity') -and
        $readerWorkerTypeFunction.Contains('GroundQueueHighWater') -and
        $readerWorkerTypeFunction -match
          'TryEnqueue[\s\S]*channel\.Dispose\(\)[\s\S]*fixed queue overflowed fail-closed' -and
        $readerWorkerTypeFunction -match
          'Receive\(int\s+timeoutMs\)[\s\S]*ReadExactWithDeadline' -and
        $readerWorkerTypeFunction -match
          'StopCapture\(int\s+timeoutMs\)[\s\S]*ReceiveDrain\(timeoutMs\)' -and
        $readerWorkerTypeFunction -match
          'StopAndJoin\(int\s+timeoutMs\)[\s\S]*StopCapture\(timeoutMs\)' -and
        $readerWorkerTypeFunction -match
          'CloseExit\(int\s+timeoutMs\)[\s\S]*ReceiveBounded\(timeoutMs\)' -and
        $readerWorkerTypeFunction -match
          'ReceiveBounded\(int\s+timeoutMs\)[\s\S]*channel\.Receive\(timeoutMs\)') `
      -Detail 'Parent-side role queues are fixed and negotiated with explicit high-water/depth evidence; all blocking drain/STOP/CLOSE receives honor a deadline and dispose the pipe fail-closed.'
  Add-Check -Name 'reader_broker_strict_config_initial_context_and_source_immutability' `
      -Passed ($readerBrokerStartFunction -match
          'ExpectedRunnerSha256[\s\S]*launchSourceSha256[\s\S]*launch refused source mutation' -and
        $readerBrokerStartFunction -match
          'legacy seven-argument overload[\s\S]*forbidden[\s\S]*ReaderBrokerClient\]::Connect[\s\S]*RingSlots[\s\S]*SerialReadSliceBytes[\s\S]*PumpFairnessTargetMs[\s\S]*PumpFairnessHardLimitMs[\s\S]*20,\s*2000[\s\S]*InitialPhase[\s\S]*InitialEpoch' -and
        $readerWorkerTypeFunction -match
          'HELLO_ACK requested configuration mismatch' -and
        $readerWorkerTypeFunction -match
          'ReadTimeout\s*=\s*20[\s\S]*WriteTimeout\s*=\s*2000' -and
        $readerWorkerTypeFunction -match
          'OpenAndStartCapture[\s\S]*new\s+DualPortReaderWorker[\s\S]*vehicle\.Open\(\)[\s\S]*ground\.Open\(\)[\s\S]*worker\.Start\(\)' -and
        $source -match
          'Start-ReaderBrokerClient[\s\S]{0,500}-ExpectedRunnerSha256\s+\$runnerSha256' -and
        $readerBrokerStartFunction -match
          "Scenario\s+-ceq\s+'serial'[\s\S]{0,180}'ports_opening'[\s\S]{0,220}'boot_observe'" -and
        $readerBrokerHarnessFunction -match
          "InitialPhase\s+'ports_opening'[\s\S]{0,100}InitialEpoch\s+'boot_observe'[\s\S]*ProducerPhase[\s\S]*ProducerEpoch" -and
        $readerBrokerHarnessFunction -match
          'SelfTestExpectedRingSlots\s+9[\s\S]*requested configuration mismatch') `
      -Detail 'A single initial runner hash is rechecked at launch; the strict 20-argument handshake binds ring/read/fairness/timeouts/role ports, preallocates before COM open, and maps context 0 to ports_opening/boot_observe.'
  Add-Check -Name 'reader_broker_serial_clock_anchor_is_contemporaneous' `
      -Passed ($readerClockAnchorFunction -match
          'GetTimestamp\(\)[\s\S]*RunWatch\.Elapsed\.TotalMilliseconds[\s\S]*GetTimestamp\(\)[\s\S]*qpc_origin_ticks[\s\S]*base_elapsed_ms' -and
        $readerBrokerStartFunction -match
          "QpcOriginTicks[\s\S]*callerClockPairProvided[\s\S]*Scenario\s+-ceq\s+'serial'[\s\S]*requires a caller-sampled QPC/RunWatch pair" -and
        $source -match
          '\$portsOpeningClockAnchor\s*=\s*New-ReaderClockAnchor[\s\S]{0,500}Start-ReaderBrokerClient[\s\S]{0,300}-QpcOriginTicks\s+\(\[long\]\$portsOpeningClockAnchor\.qpc_origin_ticks\)[\s\S]{0,180}-BaseElapsedMs\s+\(\[double\]\$portsOpeningClockAnchor\.base_elapsed_ms\)' -and
        -not $source.Contains('-BaseElapsedMs $portsOpeningElapsedMs') -and
        $source -match
          '\$m1Transition\.captured_elapsed_ms[\s\S]{0,900}Update-HeartbeatWindowAccumulator[\s\S]{0,220}-ThroughElapsedMs\s+\(\[double\]\$m1\.elapsed_ms\)' -and
        -not ($source -match
          'Max\s*\([^\r\n]*m1[^\r\n]*last_update_elapsed_ms')) `
      -Detail 'The serial broker maps QPC and RunWatch from one bracketed clock sample; official M1 remains the unmodified transition barrier and cannot be clamped over a stale mapping.'
  Add-Check -Name 'reader_broker_serial_clock_anchor_drives_fairness_start' `
      -Passed ($pumpFairnessClockAnchorFunction -match
          'ClockAnchor[\s\S]*base_elapsed_ms[\s\S]*New-PumpFairnessState[\s\S]*-StartedElapsedMs\s+\$startedElapsedMs[\s\S]*started_elapsed_ms[\s\S]*vehicle[\s\S]*ground' -and
        $source -match
          '\$portsOpeningClockAnchor\s*=\s*New-ReaderClockAnchor[\s\S]{0,900}Start-ReaderBrokerClient\s+-Scenario\s+''serial''[\s\S]{0,500}-QpcOriginTicks\s+\(\[long\]\$portsOpeningClockAnchor\.qpc_origin_ticks\)[\s\S]{0,220}-BaseElapsedMs\s+\(\[double\]\$portsOpeningClockAnchor\.base_elapsed_ms\)[\s\S]{0,900}\$vehicleSerial\.Open\(\)[\s\S]{0,180}\$groundSerial\.Open\(\)[\s\S]{0,300}\$script:PumpFairness\s*=\s*New-PumpFairnessStateFromReaderClockAnchor[\s\S]{0,160}-ClockAnchor\s+\$portsOpeningClockAnchor[\s\S]{0,220}Set-ReaderCaptureContext' -and
        ([regex]::Matches($source,
          'New-PumpFairnessStateFromReaderClockAnchor\s+`?\s*-ClockAnchor\s+\$portsOpeningClockAnchor')).Count -eq 1) `
      -Detail 'The live serial path passes one bracketed clock anchor to both the broker mapping and the validated fairness-state constructor before capture begins.'
  Add-Check -Name 'reader_broker_exact_acceptance_copied_to_live_lifecycle' `
      -Passed ($readerBrokerCloseFunction -match
          'ExpectedExactFixtureAttempted[\s\S]*ExpectedExactFixtureAccepted[\s\S]*ExactFixtureAttempted[\s\S]*ExactFixtureAccepted[\s\S]*GroundWrittenBytes[\s\S]*GroundWriteOperationCount[\s\S]*GroundFlushCount[\s\S]*lifecycle_valid' -and
        $readerBrokerStartFunction -match
          'context_id=\[uint32\]\$client\.ContextId' -and
        $source -match
          'ExpectedExactFixtureAttempted[\s\S]{0,160}\$injection\.attempt_count\s+-eq\s+1[\s\S]{0,200}ExpectedExactFixtureAccepted[\s\S]{0,160}\$injection\.write_count\s+-eq\s+1' -and
        $source -match
          'reader_broker_lifecycle\.json') `
      -Detail 'Live PASS requires the parent acknowledged write count and child exact-once latch to agree; non-injection exits explicitly expect a false child latch.'
  Add-Check -Name 'pump_fairness_hard_limit_is_fail_closed' `
      -Passed ($source -match (
        'Get-PumpFairnessEvidence[\s\S]{0,1000}' +
        'if\s*\([\s\S]{0,160}-not\s+\$pumpFairnessEvidence\.valid\)' +
        '[\s\S]{0,600}\$preCloseStatus\s*=\s*''FAIL''') -and
        $source -match
        'pump_fairness\.json[\s\S]{0,300}\$pumpFairnessEvidence') `
      -Detail 'Any measured service gap or read+parse stall at/above 100 ms prevents a PASS and remains explicit in pump_fairness.json.'
  Add-Check -Name 'readiness_pump_checkpoint_requires_open_parser_epoch' `
      -Passed ($readinessPumpCheckpointFunction -match
        'GroundParser\.Enabled[\s\S]*Epoch\.closed[\s\S]*throw[\s\S]*Invoke-PumpPair' -and
        $readinessPumpCheckpointFunction -match
        'vehicleServiceCountBefore[\s\S]*groundServiceCountBefore[\s\S]*vehicleServiceCountAfter[\s\S]*groundServiceCountAfter[\s\S]*\[uint64\]1' -and
        $readinessPumpCheckpointFunction -match
        'ground_parser_enabled_before[\s\S]*ground_parser_enabled_after[\s\S]*epoch_open_before[\s\S]*epoch_open_after' -and
        $readinessGateFunction -match
          'readiness_entry_epoch_open[\s\S]*readiness_entry_after_setup' -and
        $readinessGateFunction -match
          'bracket_[^'']*_after_assessment[\s\S]*bracket_[^'']*_after_window_row[\s\S]*bracket_[^'']*_after_progress_fsync' -and
        $source -match
          '\$script:MaxReadinessPumpCheckpointEvents\s*=\s*\[int\]4096' -and
        $source -match
          '\$script:ReadinessBracketCheckpointCount\s*=\s*\[int\]8' -and
        $readinessCheckpointBoundFunction -match
          'pipelineReserveSeconds[\s\S]*availableFiveSecondWindows[\s\S]*candidateCount[\s\S]*passiveCount[\s\S]*scheduledFsyncCheckpointCount[\s\S]*calculated_checkpoint_maximum[\s\S]*valid') `
      -Detail 'Readiness opens an epoch before setup and fail-closed checkpoints split setup, both forced A/B raw-fsync boundaries, assessment, evidence-row, and progress work while proving one service per role.'
  Add-Check -Name 'readiness_forced_raw_fsync_boundary_is_fail_closed' `
      -Passed ($readinessRawFsyncBoundaryFunction -match
        'LastRawFlushElapsedMs[\s\S]*VehicleState\.RawStream\.Flush\(\$true\)[\s\S]*Invoke-ReadinessPumpCheckpoint[\s\S]*GroundState\.RawStream\.Flush\(\$true\)[\s\S]*Invoke-ReadinessPumpCheckpoint[\s\S]*RawCaptureFlushIntervalMs[\s\S]*throw[\s\S]*last_raw_flush_elapsed_ms[\s\S]*pump_checkpoints') `
      -Detail 'A forced readiness raw-fsync boundary durably flushes both streams, services both roles between operations, and refuses any completed boundary beyond the 30-second hard interval.'
  Add-Check -Name 'readiness_raw_fsync_age_decision_preserves_30s_hard_limit' `
      -Passed ($readinessRawFsyncAgeFunction -match
        'LastRawFlushElapsedMs[\s\S]*CurrentElapsedMs[\s\S]*RawCaptureFlushIntervalMs[\s\S]*age_ms[\s\S]*valid' -and
        $readinessRawFsyncBoundaryFunction -match
        'Get-ReadinessRawFsyncAgeDecision[\s\S]*if\s*\(-not\s+\$startDecision\.valid\)[\s\S]*throw[\s\S]*Flush\(\$true\)[\s\S]*Get-ReadinessRawFsyncAgeDecision[\s\S]*if\s*\(-not\s+\$finishedDecision\.valid\)[\s\S]*throw') `
      -Detail 'Both entry age and completed-boundary age are checked against the unchanged 30000 ms hard limit, so a late or slow fsync cannot hide a durability breach.'
  Add-Check -Name 'readiness_idle_fsync_clock_propagates_to_outer_gate' `
      -Passed ($pumpToIdleFunction -match
        'LastRawFlushElapsedMs[\s\S]*activityObserved[\s\S]*Invoke-ReadinessRawFsyncBoundary[\s\S]*pump_checkpoints[\s\S]*bytes_read[\s\S]*reader_barrier_drain\.bytes_drained[\s\S]*activityObserved[\s\S]*last_raw_flush_elapsed_ms[\s\S]*if\s*\(-not\s+\$activityObserved\)[\s\S]*idlePolls[\s\S]*raw_fsync_pump_checkpoints' -and
        $readinessGateFunction -match
        'Invoke-PumpPairUntilIdle[\s\S]*-LastRawFlushElapsedMs\s+\$lastRawFlushElapsedMs[\s\S]*idleResult\.raw_fsync_pump_checkpoints[\s\S]*\$lastRawFlushElapsedMs\s*=\s*\[double\]\$idleResult\.last_raw_flush_elapsed_ms') `
      -Detail 'Any scheduled fsync completed while pumping to idle returns its exact clock and checkpoints to the outer readiness durability account.'
  Add-Check -Name 'identity_inventory_does_not_allow_null' `
      -Passed (-not $identityFunction.Contains('AllowNull')) `
      -Detail 'Empty inventory is permitted, but null inventory remains rejected.'
  $selfTestFunction = Get-FunctionText -Ast $ast `
      -Name 'Invoke-OfflineSelfTest'
  Add-Check -Name 'vehicle_hb_grant_diag_reads_exact_vcstat3_uint64' `
      -Passed ($vcstat3UInt64Function -match
        '(?s)Snapshot.*Key.*status.*COMPLETE.*responses.*tag.*-c(?:eq|ne)\s+''VCSTAT3''.*PSObject\.Properties\[\$Key\].*\[uint64\]::TryParse.*vcstat3_count.*uint64_valid.*valid') `
      -Detail 'hgd/hdm evidence is accepted only from the exact Vehicle VCSTAT3 response and only after UInt64.TryParse succeeds.'
  Add-Check -Name 'vehicle_native_diag_reads_exact_vcstat3_string' `
      -Passed ($vcstat3StringFunction -match
        '(?s)Snapshot.*Key.*status.*COMPLETE.*responses.*tag.*-c(?:eq|ne)\s+''VCSTAT3''.*PSObject\.Properties\[\$Key\].*vcstat3_count.*field_present.*valid') `
      -Detail 'Fixed-width hexadecimal native-list evidence is accepted only from the single exact Vehicle VCSTAT3 response.'
  Add-Check -Name 'vehicle_hb_grant_diag_three_phase_monotonic_hdm_zero' `
      -Passed ($heartbeatGrantDiagnosticFunction -match
        '(?s)\A(?=.*BaselineVehicle)(?=.*M0Vehicle)(?=.*M1Vehicle)(?=.*hgd)(?=.*hdm)(?=.*Get-VehicleVcstat3UInt64)(?=.*baseline_to_m0)(?=.*m0_to_m1)(?=.*baseline_to_m1)(?=.*monotonic_non_decreasing)(?=.*hdm_delta_zero)(?=.*minimum_delta_required)(?=.*valid)') `
      -Detail 'The auxiliary contract records baseline/M0/M1 values and all deltas, permits hgd delta zero, and requires hdm delta zero.'
  [string[]]$groundRecoveryDiagnosticKeys = @(
    'mcr','rfpbs','rfpfa','rfpno','rfpbl','rfpcr','rfpum','rfpuf','rfprs',
    'rfpbuf','rfdmbuf','rfdmesc','ppre','pvto','pract','prold','prfut','prgap',
    'prto','prq','prtx','prv','prusb','punm','prlv','prlr','prlex','prlrx',
    'prlcnt','prlseq','prlms')
  [bool]$baselineRecoverySchemaComplete = $true
  foreach ($recoveryKey in $groundRecoveryDiagnosticKeys) {
    if ([regex]::Matches($baselineFunction,
        "'" + [regex]::Escape($recoveryKey) + "'").Count -lt 1) {
      $baselineRecoverySchemaComplete = $false
    }
  }
  Add-Check -Name 'baseline_requires_recovery_latch_and_rf_parser_schema' `
      -Passed $baselineRecoverySchemaComplete `
      -Detail 'The official baseline rejects any missing GCSTAT3 precommit, recovery, first-latch, RF-parser, or demux field.'
  [string[]]$vehicleNativeClassificationKeys = @(
    'sncsf','sncsb','sncof','sncob','snfsf','snfof','snffm','snflm','snfmg',
    'snftr','sncerr','snul','snur','snuv','snusg','snusz','snup','snusy',
    'snucp','snusq','snumask','snuval','snui','snuc','snut','snums','snuid')
  [bool]$baselineNativeClassificationSchemaComplete = $true
  [bool]$postNativeClassificationSchemaComplete = $true
  foreach ($classificationKey in $vehicleNativeClassificationKeys) {
    if ([regex]::Matches($baselineFunction,
        "'" + [regex]::Escape($classificationKey) + "'").Count -lt 1) {
      $baselineNativeClassificationSchemaComplete = $false
    }
    if ([regex]::Matches($postFunction,
        "'" + [regex]::Escape($classificationKey) + "'").Count -lt 1) {
      $postNativeClassificationSchemaComplete = $false
    }
  }
  Add-Check -Name 'baseline_requires_native_classification_schema' `
      -Passed $baselineNativeClassificationSchemaComplete `
      -Detail 'Every numeric and fixed-width hexadecimal native-list classification/latch field is mandatory before request injection.'
  Add-Check -Name 'post_requires_native_classification_schema' `
      -Passed $postNativeClassificationSchemaComplete `
      -Detail 'Post acceptance consumes every native-list classification partition, timing, error, and first-unexpected latch field.'
  [string[]]$nativeAccountingCheckNames = @(
    'vehicle_native_cancel_frame_partition_exact',
    'vehicle_native_cancel_byte_partition_exact',
    'vehicle_native_stat_runtime_cancel_bytes_exact',
    'vehicle_native_cancelled_frame_bytes_exact',
    'vehicle_native_other_cancelled_zero',
    'vehicle_native_filter_frame_partition_exact',
    'vehicle_native_other_filtered_zero',
    'vehicle_native_classification_errors_zero',
    'vehicle_native_filter_time_regressions_zero',
    'vehicle_native_filter_timestamps_coherent',
    'vehicle_native_unexpected_latch_clear',
    'vehicle_native_unexpected_value_hex8_zero',
    'vehicle_native_unexpected_id_hex32_zero',
    'vehicle_d7_param_value_full_partition_exact',
    'vehicle_target_frames_queued_exact',
    'vehicle_target_selections_exact',
    'vehicle_target_chunks_exact',
    'vehicle_target_frames_completed_exact',
    'vehicle_target_duplicates_zero',
    'vehicle_target_rejected_zero')
  [bool]$nativeAccountingChecksDeclaredExactlyOnce = $true
  foreach ($accountingCheckName in $nativeAccountingCheckNames) {
    if ([regex]::Matches($postFunction,
        "name='" + [regex]::Escape($accountingCheckName) + "'").Count -ne 1) {
      $nativeAccountingChecksDeclaredExactlyOnce = $false
    }
  }
  Add-Check -Name 'post_native_classification_accounting_is_explicit' `
      -Passed ($nativeAccountingChecksDeclaredExactlyOnce -and
        $postFunction -match
          '(?s)sncf.*sncsf.*sncof.*sncb.*sncsb.*sncob.*37.*snff.*snfsf.*snfof' -and
        $postFunction -match '(?s)sncb.*37.*sncf' -and
        $postFunction -match
          '(?s)d722.*sncf.*snff.*snq.*stqf' -and
        $postFunction -match
          '(?s)stqf.*stsel.*stdone.*stchunk.*stdup.*strej' -and
        $postFunction -match
          '(?s)snuid.*\^\[0-9A-Fa-f\]\{32\}\$') `
      -Detail 'The post oracle uses both sncb=37*sncf and exact-class partitions plus target-lane conservation, rejects all other/unclassified/unexpected evidence, and validates snuid as exactly 32 hexadecimal characters.'
  [string[]]$absoluteZeroCounterKeys = @(
    'snbusy','snseq','stdup','strej','sncof','sncob','snfof','sncerr','snftr',
    'cc','rcr','riv','ocr','oiv','eiv','eov','out','d6cr','d7cr','pvbad',
    'pvov','eo','sc','evo','mcr','rfpno','rfpbl','rfpcr','rfpum','rfpuf')
  [bool]$absoluteZeroSchemaComplete = $true
  foreach ($absoluteZeroKey in $absoluteZeroCounterKeys) {
    if ([regex]::Matches($baselineFunction,
        "'" + [regex]::Escape($absoluteZeroKey) + "'").Count -lt 1 -or
        [regex]::Matches($postFunction,
        "'" + [regex]::Escape($absoluteZeroKey) + "'").Count -lt 1) {
      $absoluteZeroSchemaComplete = $false
    }
  }
  Add-Check -Name 'power_cycle_error_and_parser_counters_absolute_zero' `
      -Passed ($absoluteZeroSchemaComplete -and
        $baselineFunction -match 'power_cycle_clean_baseline_zero_' -and
        $postFunction -match 'baseline_post_and_delta_zero' -and
        $selfTestFunction -match
          'post_native_preexisting_abnormal_zero_delta_rejected') `
      -Detail 'Power-cycle HIL rejects preexisting nonzero native, target, Vehicle error, and RF parser counters even when their deltas remain zero.'
  Add-Check -Name 'baseline_requires_named_ppre_presence_check' `
      -Passed ($baselineFunction -match
        '@\(''ground_native_diagnostic_ppre_present''\s*,\s*\$GroundSnapshot\s*,\s*''ppre''\)') `
      -Detail 'The precommit-quarantine subset is a mandatory UInt64 field in the exact Ground baseline snapshot.'
  Add-Check -Name 'baseline_treats_rfdmesc_as_enabled_mode_not_pending_escape' `
      -Passed ($baselineFunction -match
        "@\('ground_radio_demux_escape_mode_enabled'\s*,\s*\`$GroundSnapshot\s*,\s*'rfdmesc'\s*,\s*\[uint64\]1\)") `
      -Detail 'rfdmesc reports the configured link-data escaping mode, which is enabled; rfdmbuf separately proves there is no pending escape/candidate.'
  Add-Check -Name 'baseline_requires_demux_buffer_exactly_empty' `
      -Passed ($baselineFunction -match
        "@\('ground_radio_demux_buffer_empty'\s*,\s*\`$GroundSnapshot\s*,\s*'rfdmbuf'\s*,\s*\[uint64\]0\)") `
      -Detail 'Baseline independently requires the demux candidate/escape buffer to be present and exactly zero.'
  [bool]$postRecoveryPathSchemaComplete = $true
  foreach ($recoveryPathKey in @(
      'pract','prgap','prto','pvto','prlv','prlr','prlex','prlrx','prlcnt',
      'prlseq','prlms')) {
    if ([regex]::Matches($postFunction,
        "'" + [regex]::Escape($recoveryPathKey) + "'").Count -lt 1) {
      $postRecoveryPathSchemaComplete = $false
    }
  }
  Add-Check -Name 'post_has_three_disjoint_native_stream_paths' `
      -Passed ($postRecoveryPathSchemaComplete -and $postFunction -match
        '(?s)native_stream_path.*NORMAL.*FUTURE_INDEX_RECOVERY.*INTER_VALUE_TIMEOUT_RECOVERY') `
      -Detail 'Normal native success remains strict and only the two named, latch-proven recovery paths can pass.'
  Add-Check -Name 'recovery_idle_latch_sentinel_and_observation_interval_exact' `
      -Passed ($baselineFunction -match
        "ground_proxy_recovery_latch_received_sentinel[\s\S]*'prlrx'[\s\S]*65535" -and
        $postFunction -match
        '(?s)normalRecoveryGaugeExpected.*prlrx\s*=\s*\[uint64\]65535' -and
        $postFunction -match
        '(?s)baseline_ms<prlms<=post_ms.*latchObservedTime.*-gt.*baselineLatchTime.*-le.*postLatchTime') `
      -Detail 'Idle latch uses the FFFF sentinel, while a recovery latch time must be inside the exact baseline/post device-time interval.'
  [bool]$postRecoveryAccountingSchemaComplete = $true
  foreach ($recoveryAccountKey in @(
      'prq','prtx','prv','prusb','punm','pgen','ptx','deq','rf22','pnq',
      'ppre')) {
    if ([regex]::Matches($postFunction,
        "'" + [regex]::Escape($recoveryAccountKey) + "'").Count -lt 1) {
      $postRecoveryAccountingSchemaComplete = $false
    }
  }
  Add-Check -Name 'post_recovery_accounting_is_relational_not_threshold_only' `
      -Passed ($postRecoveryAccountingSchemaComplete -and
        $postFunction -match
        '(?s)ExpectedParamCount.*prlex' -and
        $postFunction -match
        '(?s)MatchingUsbParamValues.*932') `
      -Detail 'Recovery admission is tied to exact generated/accepted/seen/USB accounting, the missing tail, future plus precommit RF quarantine, and unchanged exact USB cardinality.'
  Add-Check -Name 'post_requires_named_ppre_presence_and_monotonicity' `
      -Passed ($postFunction -match
        '(?s)\$precommitQuarantineEvidence\s*=\s*\$recoveryDeltas\[''ppre''\].{0,240}name=''ground_proxy_precommit_quarantine_present'';key=''ppre''\s*rule=''baseline_and_post_present_monotonic'';expected=\$true.{0,500}valid=\(\$precommitQuarantineEvidence\.found\s+-and\s+\$precommitQuarantineEvidence\.monotonic\).{0,300}\$recoveryEvidenceComplete\s*=\s*\$false') `
      -Detail 'Post acceptance has an explicit named ppre check, rejects a missing or decreasing counter, and folds that failure into complete path evidence.'
  Add-Check -Name 'post_normal_quarantine_is_exact_precommit_subset' `
      -Passed ($postFunction -match
        '(?s)\$normalQuarantine\s*=\s*\$recoveryDeltas\[''pnq''\].{0,300}\$normalPrecommitQuarantine\s*=\s*\$recoveryDeltas\[''ppre''\]' -and
        $postFunction -match
        '(?s)name=''ground_proxy_native_quarantine_is_precommit_only''\s*key=''pnq==ppre'';rule=''exact_relation'';expected=''equal''.{0,700}valid=\(\$normalQuarantine\.found\s+-and\s+\$normalQuarantine\.monotonic\s+-and\s+\$normalPrecommitQuarantine\.found\s+-and\s+\$normalPrecommitQuarantine\.monotonic\s+-and\s+\[uint64\]\$normalQuarantine\.delta\s+-eq\s+\[uint64\]\$normalPrecommitQuarantine\.delta\)' -and
        $postFunction -match
        '(?s)ground_proxy_native_poison_zero.{0,180}''ppois''\s+0' -and
        $postFunction -match
        '(?s)\$normalRecoveryEvidence.{0,1400}normalRecoveryGaugeExpected.{0,1200}if\s*\(\$normalRecoveryEvidence\)\s*\{\s*\$nativeStreamPath\s*=\s*''NORMAL''') `
      -Detail 'NORMAL accepts quarantine only when both UInt64 deltas are present/monotonic and pnq equals its complete ppre subset, with poison zero and the recovery latch in its exact idle state.'
  Add-Check -Name 'post_normal_rf22_includes_precommit_quarantine' `
      -Passed ($postFunction -match
        '(?s)\[uint64\]\$normalExpectedRf22\s*=\s*\[uint64\]\$script:ExpectedParamCount\s*\+\s*\[uint64\]\$normalQuarantine\.delta.{0,500}name=''ground_rf_param_values_exact'';key=''rf22''\s*rule=''932_plus_precommit_quarantine''.{0,1000}\$recoveryDeltas\[''rf22''\]\.delta\s+-eq\s+\$normalExpectedRf22') `
      -Detail 'NORMAL RF evidence counts all 932 indexed values plus every causally isolated precommit PARAM_VALUE; USB cardinality remains exactly 932.'
  Add-Check -Name 'post_recovery_quarantine_is_future_plus_precommit' `
      -Passed ($postFunction -match
        '(?s)name=''ground_recovery_quarantine_is_future_or_precommit''\s*key=''pnq==prfut\+ppre'';rule=''exact_relation''\s*expected=''sum''.{0,1200}\[uint64\]\$recoveryDeltas\[''pnq''\]\.delta\s+-eq\s*\(\[uint64\]\$recoveryDeltas\[''prfut''\]\.delta\s*\+\s*\[uint64\]\$recoveryDeltas\[''ppre''\]\.delta\)' -and
        $postFunction -match
        '(?s)\$expectedRf22\s*=\s*\[uint64\]\$script:ExpectedParamCount\s*\+\s*\[uint64\]\$recoveryDeltas\[''pnq''\]\.delta.{0,500}ground_rf_param_values_recovery_exact') `
      -Detail 'Recovery quarantine is neither relaxed nor double-counted: pnq must equal the exact sum of future-index and precommit subsets, and RF #22 remains 932 plus pnq.'
  [bool]$postRecoveryRfSchemaComplete = $true
  foreach ($recoveryRfKey in @(
      'mcr','rfpbs','rfpfa','rfpno','rfpbl','rfpcr','rfpum','rfpuf',
      'rfprs','rfpbuf','rfdmbuf','rfdmesc')) {
    if ([regex]::Matches($postFunction,
        "'" + [regex]::Escape($recoveryRfKey) + "'").Count -lt 1) {
      $postRecoveryRfSchemaComplete = $false
    }
  }
  Add-Check -Name 'post_recovery_rf_parser_fail_closed' `
      -Passed $postRecoveryRfSchemaComplete `
      -Detail 'Ground RF MAVLink parser and demux evidence is mandatory and fail-closed for every native success path.'
  Add-Check -Name 'post_treats_rfdmesc_as_enabled_mode_not_pending_escape' `
      -Passed ($postFunction -match
        "ground_radio_demux_escape_mode_enabled_post[\s\S]{0,300}'rfdmesc'[\s\S]{0,300}\[uint64\]1") `
      -Detail 'Post-state requires the configured escaping mode to remain enabled while the separate demux buffer must be empty.'
  Add-Check -Name 'post_requires_demux_buffer_exactly_empty' `
      -Passed ($postFunction -match
        "ground_radio_demux_buffer_empty_post[\s\S]{0,200}'rfdmbuf'[\s\S]{0,500}expected=\[uint64\]0[\s\S]{0,300}actual=\`$reading\.value[\s\S]{0,300}\`$reading\.found") `
      -Detail 'Post-state independently records and requires the demux candidate/escape buffer to be present and exactly zero.'

  Add-Check -Name 'directed_future_fault_is_explicit_opt_in_default_normal' `
      -Passed ($source -match
          "ValidateSet\('NORMAL','FUTURE_INDEX_RECOVERY'\)[\s\S]{0,120}ExpectedDiagnosticFaultMode\s*=\s*'NORMAL'" -and
        $source -match
          'ValidateRange\(0,\s*931\)[\s\S]{0,100}ExpectedDiagnosticFaultDropIndex\s*=\s*930' -and
        $source -match
          "ExpectedDiagnosticFaultMode\s+-ceq\s+'FUTURE_INDEX_RECOVERY'[\s\S]{0,180}ExpectedDiagnosticFaultDropIndex\s+-ne\s*930[\s\S]{0,180}throw") `
      -Detail 'The deterministic fault expectation is opt-in, defaults to NORMAL, and only the compile-time index-930 variant is accepted.'
  Add-Check -Name 'directed_future_fault_post_contract_is_exact_not_threshold' `
      -Passed ($postFunction -match
          "ExpectedDiagnosticFaultMode[\s\S]*ExpectedDiagnosticFaultDropIndex" -and
        $postFunction -match
          "directed_future_path_exact[\s\S]{0,500}FUTURE_INDEX_RECOVERY" -and
        $postFunction -match
          "directedLatchExpected[\s\S]{0,500}expected_index=\[uint64\]\`$ExpectedDiagnosticFaultDropIndex[\s\S]{0,300}received_index=\[uint64\]\(\`$ExpectedDiagnosticFaultDropIndex\s*\+\s*1\)[\s\S]{0,300}received_count=\[uint64\]\`$script:ExpectedParamCount[\s\S]{0,200}reason=\[uint64\]1" -and
        $postFunction -match
          "name='directed_future_latch_exact'[\s\S]{0,1200}\[uint64\]\`$recoveryPost\['prlex'\]\.value\s+-eq[\s\S]{0,100}\`$ExpectedDiagnosticFaultDropIndex[\s\S]{0,400}\[uint64\]\`$recoveryPost\['prlrx'\]\.value\s+-eq[\s\S]{0,100}\(\`$ExpectedDiagnosticFaultDropIndex\s*\+\s*1\)[\s\S]{0,500}\[uint64\]\`$recoveryPost\['prlcnt'\]\.value\s+-eq[\s\S]{0,100}\`$script:ExpectedParamCount[\s\S]{0,300}\[uint64\]\`$recoveryPost\['prlr'\]\.value\s+-eq\s*\[uint64\]1" -and
        $postFunction -match
          "directedFutureExactDeltas[\s\S]{0,900}pvto=\[uint64\]0[\s\S]{0,220}prgap=\[uint64\]1[\s\S]{0,220}prto=\[uint64\]0[\s\S]{0,220}prfut=\[uint64\]1[\s\S]{0,220}ppre=\[uint64\]0[\s\S]{0,220}pnq=\[uint64\]1[\s\S]{0,220}prold=\[uint64\]0" -and
        $postFunction -match
          "directedFutureMissingTail[\s\S]{0,300}ExpectedParamCount[\s\S]{0,300}ExpectedDiagnosticFaultDropIndex[\s\S]{0,500}@\('prq','prtx','prv','prusb','pgen'\)" -and
        $postFunction -match
          "directed_future_ptx_native_plus_tail_exact[\s\S]{0,200}directed_future_deq_native_plus_tail_exact" -and
        $postFunction -match
          "directedExpectedRf22[\s\S]{0,300}ExpectedParamCount[\s\S]{0,300}directedFutureExactDeltas\['pnq'\][\s\S]{0,200}\[uint64\]1[\s\S]{0,500}name='directed_future_rf22_exact'" -and
        $postFunction -match
          'exact_check_count=\$directedFutureChecks\.Count[\s\S]{0,400}\$directedFutureChecks\.Count\s+-eq\s+17') `
      -Detail 'Opt-in post acceptance pins the 930-to-931 latch and every zero/one/two/three/934 counter exactly; no >= recovery threshold can satisfy it.'
  Add-Check -Name 'directed_future_fault_live_assessment_and_summary_are_bound' `
      -Passed ($source -match
          '\$postAssessment\s*=\s*Test-PostSnapshotContract[\s\S]{0,500}-ExpectedDiagnosticFaultMode\s+\$ExpectedDiagnosticFaultMode[\s\S]{0,200}-ExpectedDiagnosticFaultDropIndex[\s\S]{0,100}\$ExpectedDiagnosticFaultDropIndex' -and
        $source -match
          '\$postAssessment\.diagnostic_fault_expectation\.verified_exact[\s\S]{0,600}\$diagnosticFaultIntervention\s*=\s*\[ordered\]@\{[\s\S]{0,600}VC_LORA_HIL_DROP_NATIVE_PARAM_INDEX_930[\s\S]{0,300}verified_exact=\$faultVerifiedExact' -and
        $source -match
          "\`$summary\['diagnostic_fault_intervention'\]\s*=[\s\S]{0,120}\`$diagnosticFaultIntervention") `
      -Detail 'The live post assessment receives the explicit expectation and only the opt-in summary records the compile-time intervention plus exact verification result.'
  Add-Check -Name 'directed_future_fault_result_binding_reachable_and_baseline_returns_preserved' `
      -Passed ($baselineFunction -match
          '(?s)return\s+\[pscustomobject\]\[ordered\]@\{\s*valid=.*?checks=\$checks\.ToArray\(\)\s*\}\s*\}\s*$' -and
        $baselineDispositionFunction -match
          '(?s)return\s+\[pscustomobject\]\[ordered\]@\{\s*action=\$action.*?fixture_write_count=0\s*\}\s*\}\s*$' -and
        $postFunction -match
          '(?s)\$postContractResult\s*=\s*\[ordered\]@\{.*?checks=\$checks\.ToArray\(\)\s*\}\s*if\s*\(\$directedFutureRequested\)\s*\{\s*\$postContractResult\[''diagnostic_fault_expectation''\]\s*=\s*\$diagnosticFaultExpectation\s*\}\s*return\s+\[pscustomobject\]\$postContractResult\s*\}\s*$') `
      -Detail 'Baseline helpers retain their explicit return values, while the directed-only assessment property is added before the single reachable post-contract return.'

  [string[]]$liveProgressReservedKeys = @('event','elapsed_s','utc','phase')
  $liveProgressReservedCollisions = New-Object `
      'System.Collections.Generic.List[object]'
  foreach ($progressCall in @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Add-LiveProgressRecord'
      }, $true))) {
    foreach ($table in @($progressCall.CommandElements | Where-Object {
          $_ -is [Management.Automation.Language.HashtableAst]
        })) {
      foreach ($pair in $table.KeyValuePairs) {
        [string]$detailKey = $pair.Item1.Extent.Text.Trim("'`"")
        if ($detailKey -cin $liveProgressReservedKeys) {
          $liveProgressReservedCollisions.Add([pscustomobject]@{
            key=$detailKey;line=$pair.Item1.Extent.StartLineNumber
          })
        }
      }
    }
  }
  Add-Check -Name 'live_progress_reserved_envelope_fail_closed' `
      -Passed ($liveProgressFunction -match
        "(?s)reservedKeys\s*=\s*@\(\s*'event'\s*,\s*'elapsed_s'\s*,\s*'utc'\s*,\s*'phase'\s*\).*?-contains\s+\[string\]\s*\`$key.*?throw.*?\`$row\[\`$key\]\s*=") `
      -Detail 'event/elapsed_s/utc/phase are generated by one envelope and a colliding detail fails before any merge/write.'
  Add-Check -Name 'live_progress_callsites_reserved_key_free' `
      -Passed ($liveProgressReservedCollisions.Count -eq 0) `
      -Detail ('reserved collisions=' +
        (($liveProgressReservedCollisions | ForEach-Object {
          $_.key + '@' + $_.line }) -join ','))
  Add-Check -Name 'backlog_progress_distinct_elapsed_and_demux_actual' `
      -Passed ($backlogDrainFunction -match
          "Get-SnapshotUInt64[\s\S]{0,150}Key\s+'rfdmbuf'" -and
        [regex]::Matches($backlogDrainFunction,
          'rfdmbuf\s*=\s*\$rfdmbuf\.value').Count -ge 2 -and
        $backlogDrainFunction -match 'gate_elapsed_s\s*=' -and
        $backlogDrainFunction -notmatch '(?m)^\s*elapsed_s\s*=') `
      -Detail 'Backlog progress retains run elapsed_s, names gate-relative elapsed separately, and records rfdmbuf in both timeline and durable progress.'
  Add-Check -Name 'acquisition_progress_elapsed_is_distinct' `
      -Passed ($source -match
          "(?s)Add-LiveProgressRecord\s+-Event\s+'progress'[\s\S]{0,300}acquisition_elapsed_s\s*=") `
      -Detail 'Acquisition-relative elapsed is named separately and cannot replace the monotonic run envelope elapsed_s.'
  [string[]]$recoverySelfCaseNames = @(
    'baseline_recovery_idle_received_sentinel_zero_rejected',
    'post_native_normal_recovery_evidence_zero_pass',
    'post_native_normal_idle_received_sentinel_zero_rejected',
    'post_native_future_recovery_latch_exact_pass',
    'post_native_timeout_recovery_latch_exact_pass',
    'post_native_recovery_latch_time_outside_interval_rejected',
    'post_native_recovery_missing_evidence_rejected',
    'post_native_recovery_reason_mismatch_rejected',
    'post_native_recovery_accounting_mismatch_rejected',
    'post_native_recovery_parser_fault_rejected',
    'post_native_recovery_nonexact_usb_still_rejected',
    'post_directed_future_index_930_exact_pass',
    'post_directed_future_index_930_generic_shape_rejected',
    'post_directed_future_index_930_counter_mismatch_rejected',
    'post_directed_future_index_930_latch_mismatch_rejected',
    'post_native_r5_classified_stat_runtime_pass',
    'post_native_classification_missing_field_rejected',
    'post_native_classification_partition_mutations_rejected',
    'post_native_cancelled_frame_bytes_mutations_rejected',
    'post_native_unexpected_latch_mutations_rejected',
    'post_native_snuid_format_mutations_rejected',
    'post_native_d722_partition_mutation_rejected',
    'post_native_target_lane_mutations_rejected',
    'post_native_filter_timing_mutations_rejected')
  $recoverySelfCaseNames +=
      'post_native_preexisting_abnormal_zero_delta_rejected'
  [bool]$recoverySelfCasesDeclaredExactlyOnce = $true
  foreach ($recoverySelfCaseName in $recoverySelfCaseNames) {
    if ([regex]::Matches($selfTestFunction,
        "Add-SelfCase\s+'" + [regex]::Escape($recoverySelfCaseName) +
        "'").Count -ne 1) {
      $recoverySelfCasesDeclaredExactlyOnce = $false
    }
  }
  Add-Check -Name 'selftest_covers_positive_and_negative_recovery_contract' `
      -Passed $recoverySelfCasesDeclaredExactlyOnce `
      -Detail 'Offline tests pin normal, general recovery, and the opt-in deterministic 930-to-931 latch with exact counter and mismatch rejection.'
  [string[]]$precommitSelfCaseNames = @(
    'post_native_precommit_quarantine_exact_subset_pass',
    'post_native_precommit_quarantine_mismatch_rejected')
  [bool]$precommitSelfCasesDeclaredExactlyOnce = $true
  foreach ($precommitSelfCaseName in $precommitSelfCaseNames) {
    if ([regex]::Matches($selfTestFunction,
        "Add-SelfCase\s+'" + [regex]::Escape($precommitSelfCaseName) +
        "'").Count -ne 1) {
      $precommitSelfCasesDeclaredExactlyOnce = $false
    }
  }
  Add-Check -Name 'selftest_covers_precommit_subset_pass_and_rejection' `
      -Passed $precommitSelfCasesDeclaredExactlyOnce `
      -Detail 'Offline tests pin both the attributed precommit PASS case and pnq/ppre or RF-accounting mismatch rejection.'
  Add-Check -Name 'selftest_native_post_schema_includes_ppre_and_relation' `
      -Passed ($selfTestFunction -match
        '(?s)\$nativePostCheckNames\s*=\s*@\(.{0,1200}ground_proxy_native_poison_zero.{0,300}ground_proxy_native_quarantine_is_precommit_only.{0,500}\$nativePostChecks\.Count\s+-eq\s+\$nativePostCheckNames\.Count') `
      -Detail 'The clean native self-test audits the named Vehicle classification checks plus poison and the pnq==ppre precommit relation exactly once.'
  Add-Check -Name 'vehicle_hb_grant_diag_live_result_is_artifact_and_pass_gate' `
      -Passed ($source -match
        '(?s)\$vehicleHeartbeatGrantDiagnostics\s*=\s*Test-VehicleHeartbeatGrantDiagnosticContract.*-BaselineVehicle\s+\$baselineVehicle.*-M0Vehicle\s+\$preRequestVehicle.*-M1Vehicle\s+\$postVehicle' -and
        $source -match
        '(?s)\$heartbeatMetrics\.valid.*\$vehicleHeartbeatGrantDiagnostics\.valid' -and
        $source -match
        '(?s)vehicle_heartbeat_grant_diagnostics\.json.*snapshots\.json.*vehicle_heartbeat_grant_diagnostics\s*=\s*\$vehicleHeartbeatGrantDiagnostics' -and
        $source -match
        '(?s)\$summary\s*=.*vehicle_heartbeat_grant_diagnostics\s*=\s*\$vehicleHeartbeatGrantDiagnostics') `
      -Detail 'The live runner evaluates the three Vehicle snapshots, writes durable auxiliary evidence, mirrors it into snapshots/summary, and includes it in PASS.'
  Add-Check -Name 'serial_read_slice_31_32_33_boundaries_are_pinned' `
      -Passed ($selfTestFunction -match (
        '(?s)\A(?=.*\$script:SerialReadSliceBytes\s*-eq\s*32)' +
        '(?=.*Get-SerialReadSliceSize\s+-Available\s+31\s+' +
          '-BufferLength\s+4096\)\s*-eq\s*31)' +
        '(?=.*Get-SerialReadSliceSize\s+-Available\s+32\s+' +
          '-BufferLength\s+4096\)\s*-eq\s*32)' +
        '(?=.*Get-SerialReadSliceSize\s+-Available\s+33\s+' +
          '-BufferLength\s+4096\)\s*-eq\s*32)' +
        '(?=.*Add-SelfCase\s+''serial_read_slice_bounds_32_bytes'')')) `
      -Detail 'The 32-byte read limit has exact 31/32/33 offline boundary coverage under the renamed self-case.'
  $unsafeParamEventEnumerations = [regex]::Matches($source,
      '@\(\$(?:GroundParser\.ParamList|officialParamListState|' +
      'postCutoffParamListState)\.events\)')
  Add-Check -Name 'no_ps51_generic_param_event_array_subexpression' `
      -Passed ($unsafeParamEventEnumerations.Count -eq 0) `
      -Detail ('unsafe_live_site_count=' +
        $unsafeParamEventEnumerations.Count)
  Add-Check -Name 'readiness_param_events_use_to_array' `
      -Passed ($paramEventCopyFunction -match
        'foreach\s*\([\s\S]*\$SourceState\.events\.ToArray\(\)\s*\)' -and
        $readinessGateFunction.Contains('Complete-ReadinessParserEpoch')) `
      -Detail 'Shared live readiness epoch closure must enumerate Generic.List via ToArray().' 
  Add-Check -Name 'official_param_events_use_to_array' `
      -Passed ($source -match
        'foreach\s*\(\s*\$event\s+in\s+' +
        '\$officialParamListState\.events\.ToArray\(\)\s*\)') `
      -Detail 'Official event finalization must use Generic.List.ToArray().'
  Add-Check -Name 'post_cutoff_param_events_use_to_array' `
      -Passed ($source -match
        'foreach\s*\(\s*\$event\s+in\s+' +
        '\$postCutoffParamListState\.events\.ToArray\(\)\s*\)') `
      -Detail 'Post-cutoff event finalization must use Generic.List.ToArray().'
  $progressFunction = Get-FunctionText -Ast $ast `
      -Name 'Write-ProgressIfDue'
  $streamSealFunction = Get-FunctionText -Ast $ast `
      -Name 'Seal-EvidenceStreamsBeforeRawHash'
  $snapshotTextFunction = Get-FunctionText -Ast $ast `
      -Name 'Write-SnapshotText'
  foreach ($scoped in @(
      @('scoped_fixture_semantics', $fixtureFunction,
        'Bytes\.Length\s+-ne\s+14[\s\S]*ExpectedFixtureHex[\s\S]*ExpectedFixtureSha256[\s\S]*Extra\s+159'),
      @('scoped_list_exact_acceptance', $listFunction,
        'indexed_frame_count\s+-eq\s+932[\s\S]*unique_count\s+-eq\s+932[\s\S]*duplicate_count\s+-eq\s+0[\s\S]*unique_param_id_count\s+-eq\s+932[\s\S]*extra_param_value_count\s+-eq\s+0'),
      @('scoped_param_source_id_type_sentinel', $paramFunction,
        'SystemId\s+-ne\s+1[\s\S]*ComponentId\s+-ne\s+1[\s\S]*ExpectedStatRuntimeIdHex[\s\S]*duplicate_param_id_count[\s\S]*invalid_param_type_count'),
      @('scoped_param_capture_scope_is_explicit',
        ($paramStateFunction + "`n" + $paramFunction),
        'CaptureScope[\s\S]*capture_scope[\s\S]*capture_scope\s*=\s*(?:\[string\])?\$State\.capture_scope'),
      @('scoped_first_anomaly_metadata_frozen',
        ($paramAnomalyFunction + "`n" + $paramFunction),
        'first_anomaly[\s\S]*anomaly_class[\s\S]*elapsed_ms[\s\S]*raw_start_offset[\s\S]*raw_end_offset_exclusive[\s\S]*Register-ParamListAnomaly'),
      @('scoped_param_event_cap_refuses_truncation',
        ($paramStateFunction + "`n" + $paramEventFunction + "`n" +
          $paramFunction),
        'MaxParamValueEvidenceEvents[\s\S]*max_event_count[\s\S]*Count\s+-ge\s+\[int\]\$State\.max_event_count[\s\S]*throw[\s\S]*refusing truncation[\s\S]*Add-ParamListEventEvidence'),
      @('scoped_param_event_retains_exact_value_bits_for_tail_tuple',
        $paramFunction,
        '(?s)\A(?=.*crc_valid\s*=\s*\$true)(?=.*param_value_hex)(?=.*Payload\[0\])(?=.*Payload\[1\])(?=.*Payload\[2\])(?=.*Payload\[3\])(?=.*X8)(?=.*Add-ParamListEventEvidence)'),
      @('scoped_pre_request_backlog_fresh_m0_only',
        $preRequestBacklogFunction,
        'ReadinessEvents[\s\S]*M0Events[\s\S]*M0EpochCompleted[\s\S]*decision_scope\s*=\s*''fresh_m0_only''[\s\S]*valid\s*=\s*\(\$M0EpochCompleted\s+-and\s+\$m0EventArray\.Count\s+-eq\s+0\)[\s\S]*veto_event_count[\s\S]*historical_readiness_event_count[\s\S]*readiness_events_audit_only[\s\S]*stale_param_value_count[\s\S]*known_stat_runtime_sentinel_count[\s\S]*historical_readiness_events[\s\S]*m0_veto_events'),
      @('scoped_param_list_diagnostic_schema',
        $paramDiagnosticFunction,
        'schema_version[\s\S]*backlog_drain_gate[\s\S]*baseline_pair_gate[\s\S]*baseline_setup[\s\S]*pre_request_pair_gate[\s\S]*pre_request_vehicle_gate[\s\S]*pre_request_backlog_gate[\s\S]*official[\s\S]*stop_reason[\s\S]*cutoff_reason[\s\S]*cutoff_elapsed_ms[\s\S]*cutoff_ground_raw_offset[\s\S]*first_anomaly[\s\S]*post_cutoff[\s\S]*proxy_terminal'),
      @('scoped_proxy_terminal_classification',
        $proxyTerminalFunction,
        'PostGround[\s\S]*pst[\s\S]*pact[\s\S]*Complete[\s\S]*Failed[\s\S]*classification'),
      @('scoped_baseline_ready_proxy_idle', $baselineFunction,
        'ground_ready[\s\S]*ground_fail[\s\S]*ground_runtime_stop[\s\S]*ground_proxy_state_idle[\s\S]*ground_proxy_mode_native[\s\S]*ground_proxy_dequeue_idle'),
      @('scoped_baseline_data_plane_positive', $baselineFunction,
        'vehicle_d7_frames_positive[\s\S]*d7f[\s\S]*ground_rf_frames_positive[\s\S]*rfv[\s\S]*ground_usb_accepted_positive[\s\S]*usbacc'),
      @('scoped_baseline_stale_generic_reconciliation', $baselineFunction,
        'vehicle_ground_param22_reconciled[\s\S]*d722[\s\S]*rf22[\s\S]*vehicle_generic_param_fifo_empty[\s\S]*pgq[\s\S]*vehicle_generic_param_inactive[\s\S]*pga[\s\S]*vehicle_pending_request_empty[\s\S]*prq[\s\S]*vehicle_priority_target_lane_empty[\s\S]*ptq[\s\S]*vehicle_egress_fail_zero[\s\S]*ef[\s\S]*ground_download_queue_empty[\s\S]*dlq[\s\S]*ground_param22_ordered_backlog_empty[\s\S]*obp22[\s\S]*related_drop_error_zero'),
      @('scoped_ground_ordered_discard_continuity',
        $groundDiscardContinuityFunction,
        'BeforeGroundSnapshot[\s\S]*AfterGroundSnapshot[\s\S]*same_boot[\s\S]*obdf[\s\S]*obdb[\s\S]*Get-SnapshotDelta[\s\S]*delta_zero[\s\S]*valid'),
      @('scoped_baseline_requires_discard_presence_and_optional_continuity',
        $baselineFunction,
        'PreviousGroundSnapshot[\s\S]*obdf[\s\S]*obdb[\s\S]*expected\s*=\s*''present''[\s\S]*Test-GroundOrderedDiscardContinuity[\s\S]*backlog_drain_to_baseline[\s\S]*ground_ordered_discard_continuity'),
      @('scoped_baseline_requires_vehicle_boot_continuity',
        $baselineFunction,
        'PreviousVehicleSnapshot[\s\S]*vehicleSameBoot[\s\S]*same_boot[\s\S]*valid[\s\S]*vehicle_boot_continuity'),
      @('scoped_baseline_retry_exact_single_failure_only',
        $baselineDispositionFunction,
        'BaselineSetup[\s\S]*AttemptNumber[\s\S]*MaxAttempts[\s\S]*RetryBudgetAvailable[\s\S]*failedChecks\.Count\s*-eq\s*1[\s\S]*vehicle_ground_param22_reconciled[\s\S]*ground_rf22[\s\S]*vehicle_d722\s*\+[\s\S]*REJECT[\s\S]*ACCEPT[\s\S]*RETRY[\s\S]*failed_check_names[\s\S]*retry_eligible'),
      @('scoped_baseline_retry_exact_known_stat_runtime_current_equal_preserved',
        ($baselineFunction + "`n" + $baselineDispositionFunction),
        '(?s)\A(?=.*known_stat_runtime_race)(?=.*classification\s*=\s*''exact_known_STAT_RUNTIME_baseline_race'')(?=.*known_stat_runtime_exact_id)(?=.*known_stat_runtime_index)(?=.*65535)(?=.*known_stat_runtime_count)(?=.*932)(?=.*known_stat_runtime_type)(?=.*known_stat_runtime_system)(?=.*known_stat_runtime_component)(?=.*known_stat_runtime_parser_buffer_empty)(?=.*known_stat_runtime_previous_pgq_empty)(?=.*known_stat_runtime_current_pgq_one)(?=.*known_stat_runtime_pga_zero)(?=.*known_stat_runtime_prq_zero)(?=.*known_stat_runtime_ptq_zero)(?=.*known_stat_runtime_d722_delta_one)(?=.*known_stat_runtime_rf22_delta_one)(?=.*known_stat_runtime_pvok_delta_one)(?=.*known_stat_runtime_d722_rf22_reconciled)(?=.*known_stat_runtime_pvms_fresh_between_snapshots)(?=.*known_stat_runtime_vehicle_same_boot)(?=.*known_stat_runtime_ground_discard_continuity)(?=.*failedChecks\.Count\s*-eq\s*1)(?=.*vehicle_generic_param_fifo_empty)(?=.*known_stat_runtime_baseline_race)(?=.*RETRY)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_baseline_retry_exact_known_stat_runtime_reconciled_partial_d7',
        ($baselineFunction + "`n" + $baselineDispositionFunction),
        '(?s)\A(?=.*known_stat_runtime_reconciled_partial_d7_race)(?=.*classification\s*=\s*''exact_known_STAT_RUNTIME_reconciled_partial_D7_baseline_race'')(?=.*known_stat_runtime_reconciled_partial_previous_d7pb_empty)(?=.*known_stat_runtime_reconciled_partial_current_d7pb_bounded)(?=.*known_stat_runtime_reconciled_partial_d7cr_delta_zero)(?=.*known_stat_runtime_parser_buffer_empty)(?=.*-cne\s*''known_stat_runtime_parser_buffer_empty'')(?=.*-ge\s*\[uint64\]1)(?=.*-le\s*\[uint64\]279)(?=.*knownStatRuntimeReconciledPartialRetryCandidate)(?=.*known_stat_runtime_reconciled_partial_d7_baseline_race)(?=.*failedChecks\.Count\s*-eq\s*1)(?=.*vehicle_generic_param_fifo_empty)(?=.*RETRY)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_baseline_R1_active_reconciled_partial_exact_observer',
        $baselineFunction,
        '(?s)\A(?=.*known_stat_runtime_active_reconciled_partial_d7_race)(?=.*classification\s*=\s*''exact_known_STAT_RUNTIME_active_reconciled_partial_D7_baseline_race'')(?=.*knownStatRuntimeActiveReconciledPartialChecks)(?=.*known_stat_runtime_parser_buffer_empty)(?=.*known_stat_runtime_pga_zero)(?=.*-cne\s*''known_stat_runtime_parser_buffer_empty'')(?=.*-cne\s*''known_stat_runtime_pga_zero'')(?=.*known_stat_runtime_active_reconciled_partial_previous_pga_empty)(?=.*known_stat_runtime_active_reconciled_partial_pga_one)(?=.*key=''pga'';expected=\[uint64\]1)(?=.*known_stat_runtime_active_reconciled_partial_previous_d7pb_empty)(?=.*known_stat_runtime_active_reconciled_partial_current_d7pb_bounded)(?=.*-ge\s*\[uint64\]1)(?=.*-le\s*\[uint64\]279)(?=.*known_stat_runtime_active_reconciled_partial_d7cr_delta_zero)(?=.*known_stat_runtime_active_reconciled_partial_previous_reconciled)(?=.*known_stat_runtime_d722_rf22_reconciled)(?=.*known_stat_runtime_d722_delta_one)(?=.*known_stat_runtime_rf22_delta_one)(?=.*known_stat_runtime_pvok_delta_one)(?=.*known_stat_runtime_active_reconciled_partial_vehicle_q_next)(?=.*known_stat_runtime_active_reconciled_partial_ground_q_next)(?=.*next_uint32_with_wrap)(?=.*known_stat_runtime_active_reconciled_partial_vehicle_ms_increased)(?=.*known_stat_runtime_active_reconciled_partial_ground_ms_increased)(?=.*known_stat_runtime_active_reconciled_partial_related_drop_error_zero)(?=.*knownStatRuntimeChecks)'),
      @('scoped_baseline_R1_active_reconciled_partial_retry_separate_bounded',
        ($baselineFunction + "`n" + $baselineDispositionFunction + "`n" +
          $officialBaselineGateFunction),
        '(?s)\A(?=.*exactActiveReconciledPartialFailureSet)(?=.*failedCheckNames\.Count\s*-eq\s*2)(?=.*failedCheckNames\s+-ccontains\s*''vehicle_generic_param_fifo_empty'')(?=.*failedCheckNames\s+-ccontains\s*''vehicle_generic_param_inactive'')(?=.*knownStatRuntimeActiveReconciledPartialRetryCandidate)(?=.*known_stat_runtime_active_reconciled_partial_d7_baseline_race)(?=.*knownStatRuntimeReconciledPartialRetryCandidate)(?=.*known_stat_runtime_reconciled_partial_d7_baseline_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*DeadlineElapsedMs)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)(?=.*RETRY)(?=.*REJECT)'),
      @('scoped_baseline_vehicle_ahead_failure_set_is_exact_and_order_independent',
        $baselineDispositionFunction,
        '(?s)\A(?=.*failedCheckNames\.Count\s*-eq\s*2)(?=.*failedCheckNames\s+-ccontains\s*''vehicle_ground_param22_reconciled'')(?=.*failedCheckNames\s+-ccontains\s*''vehicle_generic_param_fifo_empty'')(?=.*known_stat_runtime_vehicle_ahead_race)(?=.*knownStatRuntimeVehicleAheadRetryCandidate)(?=.*known_stat_runtime_vehicle_ahead_baseline_race)(?=.*RETRY)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_baseline_vehicle_ahead_exact_counter_shape',
        $baselineFunction,
        '(?s)\A(?=.*classification\s*=\s*''exact_known_STAT_RUNTIME_vehicle_ahead_baseline_race'')(?=.*known_stat_runtime_vehicle_ahead_previous_reconciled)(?=.*known_stat_runtime_vehicle_ahead_d722_delta_one)(?=.*known_stat_runtime_vehicle_ahead_rf22_delta_zero)(?=.*known_stat_runtime_vehicle_ahead_pvok_delta_one)(?=.*known_stat_runtime_vehicle_ahead_current_ahead_one)(?=.*known_stat_runtime_vehicle_ahead_previous_d7pb_empty)(?=.*known_stat_runtime_vehicle_ahead_current_d7pb_bounded)(?=.*known_stat_runtime_vehicle_ahead_d7cr_delta_zero)(?=.*-ge\s+\[uint64\]1)(?=.*-le\s+\[uint64\]279)(?=.*\[uint64\]::MaxValue)(?=.*Get-SnapshotDelta)'),
      @('scoped_baseline_vehicle_ahead_exact_safety_envelope',
        ($baselineFunction + "`n" + $baselineDispositionFunction + "`n" +
          $officialBaselineGateFunction),
        '(?s)\A(?=.*known_stat_runtime_vehicle_ahead_exact_id)(?=.*STAT_RUNTIME)(?=.*known_stat_runtime_vehicle_ahead_index)(?=.*65535)(?=.*known_stat_runtime_vehicle_ahead_count)(?=.*932)(?=.*known_stat_runtime_vehicle_ahead_type)(?=.*known_stat_runtime_vehicle_ahead_system)(?=.*known_stat_runtime_vehicle_ahead_component)(?=.*known_stat_runtime_vehicle_ahead_pvms_fresh_between_snapshots)(?=.*known_stat_runtime_vehicle_ahead_previous_pgq_empty)(?=.*known_stat_runtime_vehicle_ahead_current_pgq_one)(?=.*known_stat_runtime_vehicle_ahead_pga_zero)(?=.*known_stat_runtime_vehicle_ahead_prq_zero)(?=.*known_stat_runtime_vehicle_ahead_ptq_zero)(?=.*known_stat_runtime_vehicle_ahead_vehicle_same_boot)(?=.*known_stat_runtime_vehicle_ahead_ground_discard_continuity)(?=.*related_drop_error_zero)(?=.*MaxAttempts\s*=\s*3)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*DeadlineElapsedMs)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_baseline_R3_vehicle_ahead_empty_d7_exact_observer',
        $baselineFunction,
        '(?s)\A(?=.*foreach\s*\(\$knownCheck\s+in\s+\$knownStatRuntimeVehicleAheadChecks\))(?=.*\[string\]\$knownCheck\.name\s+-cne\s*''known_stat_runtime_vehicle_ahead_current_d7pb_bounded'')(?=.*known_stat_runtime_vehicle_ahead_empty_d7_race)(?=.*classification\s*=\s*''exact_known_STAT_RUNTIME_vehicle_ahead_empty_D7_baseline_race'')(?=.*knownStatRuntimeVehicleAheadEmptyD7Checks)(?=.*known_stat_runtime_vehicle_ahead_current_d7pb_bounded)(?=.*known_stat_runtime_vehicle_ahead_empty_current_d7pb_zero)(?=.*key=''d7pb'';expected=\[uint64\]0)(?=.*knownEmptyCurrentD7pb\.found)(?=.*\[uint64\]\$knownEmptyCurrentD7pb\.value\s*-eq\s*\[uint64\]0)(?=.*known_stat_runtime_vehicle_ahead_previous_pgq_empty)(?=.*known_stat_runtime_vehicle_ahead_previous_d7pb_empty)(?=.*known_stat_runtime_vehicle_ahead_empty_previous_pga_zero)(?=.*known_stat_runtime_vehicle_ahead_empty_previous_prq_zero)(?=.*known_stat_runtime_vehicle_ahead_empty_previous_ptq_zero)(?=.*known_stat_runtime_vehicle_ahead_empty_previous_pvs1_zero)(?=.*known_stat_runtime_vehicle_ahead_current_pgq_one)(?=.*known_stat_runtime_vehicle_ahead_pga_zero)(?=.*known_stat_runtime_vehicle_ahead_prq_zero)(?=.*known_stat_runtime_vehicle_ahead_ptq_zero)(?=.*known_stat_runtime_vehicle_ahead_single_lane_empty)(?=.*known_stat_runtime_vehicle_ahead_empty_vehicle_q_next)(?=.*known_stat_runtime_vehicle_ahead_empty_ground_q_next)(?=.*next_uint32_with_wrap)(?=.*known_stat_runtime_vehicle_ahead_empty_vehicle_ms_increased)(?=.*known_stat_runtime_vehicle_ahead_empty_ground_ms_increased)(?=.*known_stat_runtime_vehicle_ahead_vehicle_same_boot)(?=.*known_stat_runtime_vehicle_ahead_exact_id)(?=.*known_stat_runtime_vehicle_ahead_previous_reconciled)(?=.*known_stat_runtime_vehicle_ahead_current_ahead_one)(?=.*known_stat_runtime_vehicle_ahead_d722_delta_one)(?=.*known_stat_runtime_vehicle_ahead_rf22_delta_zero)(?=.*known_stat_runtime_vehicle_ahead_pvok_delta_one)(?=.*known_stat_runtime_vehicle_ahead_d7cr_delta_zero)(?=.*known_stat_runtime_vehicle_ahead_pvms_fresh_between_snapshots)(?=.*known_stat_runtime_vehicle_ahead_ground_discard_continuity)(?=.*known_stat_runtime_vehicle_ahead_related_drop_error_zero)(?=.*valid\s*=\s*\(@\(\$knownStatRuntimeVehicleAheadEmptyD7Checks\s*\|\s*Where-Object\s*\{-not\s+\$_\.valid\}\)\.Count\s*-eq\s*0)(?=.*known_stat_runtime_vehicle_ahead_empty_d7_race\s*=\s*\$knownStatRuntimeVehicleAheadEmptyD7Race)'),
      @('scoped_baseline_R3_vehicle_ahead_empty_d7_retry_separate_bounded',
        ($baselineFunction + "`n" + $baselineDispositionFunction + "`n" +
          $officialBaselineGateFunction),
        '(?s)\A(?=.*exactVehicleAheadFailureSet)(?=.*failedCheckNames\.Count\s*-eq\s*2)(?=.*failedCheckNames\s+-ccontains\s*''vehicle_ground_param22_reconciled'')(?=.*failedCheckNames\s+-ccontains\s*''vehicle_generic_param_fifo_empty'')(?=.*knownStatRuntimeVehicleAheadEmptyD7Race\s*=\s*\$BaselineSetup\.PSObject\.Properties)(?=.*knownStatRuntimeVehicleAheadEmptyD7ObserverExact\s*=\s*\()(?=.*knownStatRuntimeVehicleAheadEmptyD7Race\.Value\.valid)(?=.*knownStatRuntimeVehicleAheadEmptyD7RetryCandidate\s*=\s*\(\s*\$exactVehicleAheadFailureSet\s+-and\s*\$knownStatRuntimeVehicleAheadEmptyD7ObserverExact\s*\))(?=.*retryEligible\s*=\s*\([\s\S]*knownStatRuntimeVehicleAheadEmptyD7RetryCandidate[\s\S]*attemptAvailable\s+-and\s+\$RetryBudgetAvailable)(?=.*elseif\s*\(\$retryEligible\)[\s\S]*knownStatRuntimeVehicleAheadEmptyD7RetryCandidate[\s\S]*''known_stat_runtime_vehicle_ahead_empty_d7_baseline_race'')(?=.*knownStatRuntimeVehicleAheadRetryCandidate[\s\S]*''known_stat_runtime_vehicle_ahead_baseline_race'')(?=.*knownStatRuntimeVehicleAheadEmptyD7RetryCandidate[\s\S]*-not\s+\$attemptAvailable[\s\S]*''retry_exhausted'')(?=.*knownStatRuntimeVehicleAheadEmptyD7RetryCandidate[\s\S]*-not\s+\$RetryBudgetAvailable[\s\S]*''shared_deadline_exhausted'')(?=.*known_stat_runtime_vehicle_ahead_empty_d7_observer_exact\s*=\s*\$knownStatRuntimeVehicleAheadEmptyD7ObserverExact)(?=.*known_stat_runtime_vehicle_ahead_empty_d7_race\s*=\s*if\s*\(\$null\s+-ne\s+\$knownStatRuntimeVehicleAheadEmptyD7Race\))(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*DeadlineElapsedMs)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)(?=.*RETRY)(?=.*REJECT)'),
      @('scoped_backlog_drain_observation_uses_baseline_contract',
        $backlogObservationFunction,
        'Test-BaselineSetup[\s\S]*GroundSnapshot[\s\S]*VehicleSnapshot[\s\S]*valid'),
      @('scoped_backlog_drain_two_stable_observations',
        $backlogStableFunction,
        'FirstObservation[\s\S]*SecondObservation[\s\S]*d722[\s\S]*rf22[\s\S]*Test-GroundOrderedDiscardContinuity[\s\S]*backlog_drain_stable_pair[\s\S]*5000[\s\S]*same_boot[\s\S]*valid[\s\S]*ground_ordered_discard_continuity[\s\S]*checks'),
      @('scoped_backlog_snapshot_recovery_disposition_fail_closed',
        $backlogRecoveryDispositionFunction,
        '(?s)(?=.*Response)(?=.*AttemptNumber)(?=.*MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*MatcherBefore)(?=.*MatcherAfter)(?=.*valid)(?=.*overflow)(?=.*ACCEPT)(?=.*RESYNC)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_backlog_recovered_snapshot_continuity',
        $backlogRecoveryContinuityFunction,
        '(?s)(?=.*Role)(?=.*AnchorSnapshot)(?=.*RecoveredSnapshot)(?=.*QueryWriteCount)(?=.*same_boot)(?=.*q)(?=.*ms)(?=.*d722)(?=.*rf22)(?=.*monotonic)(?=.*valid)(?=.*checks)'),
      @('scoped_backlog_snapshot_recovery_bounded_shared_deadline',
        $backlogSnapshotRecoveryFunction,
        '(?s)(?=.*DeadlineElapsedMs)(?=.*MaxAttempts\s*=\s*3)(?=.*AnchorSnapshot)(?=.*Get-DeadlineBoundSnapshotBudget)(?=.*Invoke-SnapshotQuery)(?=.*Test-ReadinessSnapshotResponse)(?=.*Get-BacklogSnapshotRecoveryDisposition)(?=.*Reset-TagMatcherCandidate)(?=.*Invoke-(?:CaptureInterval|PumpPairUntilIdle))(?=.*ExpectedQ\s+\$null)(?=.*Test-BacklogRecoveredSnapshotContinuity)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)(?=.*retry_exhausted)(?=.*attempts)'),
      @('scoped_live_backlog_drain_bounded_and_parser_disabled',
        $backlogDrainFunction,
        '(?s)(?=.*GateStartedElapsedMs)(?=.*TimeoutSeconds)(?=.*AbsoluteDeadlineElapsedMs)(?=.*deadlineElapsedMs)(?=.*GroundParser\.Enabled\s*=\s*\$false)(?=.*Reset-MavlinkAnalysis)(?=.*Invoke-BacklogSnapshotWithRecovery)(?=.*Test-BacklogDrainStablePair)(?=.*Invoke-CaptureInterval)(?=.*5000)(?=.*previousObservation\s*=\s*\$null)(?=.*recovered)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)(?=.*timedOut)'),
      @('scoped_official_baseline_gate_bounded_retry',
        $officialBaselineGateFunction,
        '(?s)(?=.*DeadlineElapsedMs)(?=.*InitialVehicleSnapshot)(?=.*InitialGroundSnapshot)(?=.*MaxAttempts\s*=\s*3)(?=.*Get-DeadlineBoundSnapshotBudget)(?=.*Get-NextQueryId)(?=.*Invoke-SnapshotQuery)(?=.*AbsoluteDeadlineElapsedMs)(?=.*Test-ReadinessSnapshotResponse)(?=.*Test-BaselineSetup)(?=.*PreviousVehicleSnapshot)(?=.*PreviousGroundSnapshot)(?=.*Get-BaselineAttemptDisposition)(?=.*retry_exhausted)(?=.*fixture_write_count\s*=\s*0)(?=.*GroundParser\.Enabled\s*=\s*\$false)(?=.*Reset-MavlinkAnalysis)'),
      @('scoped_pre_request_vehicle_recheck',
        $preRequestVehicleFunction,
        'OfficialVehicle[\s\S]*OfficialGround[\s\S]*PreRequestVehicle[\s\S]*same_boot[\s\S]*q_next[\s\S]*d722_stable[\s\S]*d722_rf22_reconciled[\s\S]*pgq[\s\S]*pga[\s\S]*prq[\s\S]*ptq[\s\S]*ef[\s\S]*related_drop_error_zero[\s\S]*valid'),
      @('scoped_pre_request_vehicle_final_gate_requires_d7pb_empty',
        $preRequestVehicleFunction,
        '(?s)\A(?=.*OfficialVehicle)(?=.*OfficialGround)(?=.*PreRequestVehicle)(?=.*d7pb_empty[\s\S]*d7pb)(?=.*Get-SnapshotUInt64[\s\S]*PreRequestVehicle[\s\S]*d7pb)(?=.*\[uint64\][^\r\n]*\.value\s*-eq\s*(?:\[uint64\])?0)(?=.*valid\s*=\s*\(@\(\$checks\s*\|\s*Where-Object\s*\{-not\s+\$_\.valid\}\)\.Count\s*-eq\s*0\))'),
      @('scoped_pre_request_exact_stat_runtime_retry_disposition',
        $preRequestDispositionFunction,
        '(?s)(?=.*CausalGate)(?=.*PreRequestVehicleGate)(?=.*OfficialVehicle)(?=.*PreRequestVehicle)(?=.*M0Events)(?=.*AttemptNumber)(?=.*MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*known_STAT_RUNTIME_sentinel)(?=.*anomaly_classes)(?=.*parser)(?=.*heartbeat)(?=.*d722_stable)(?=.*d722_rf22_reconciled)(?=.*pgq)(?=.*Get-SnapshotDelta)(?=.*pvid)(?=.*pvidx)(?=.*pvcnt)(?=.*pvtype)(?=.*ACCEPT)(?=.*RETRY)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_exact_wire_stat_runtime_extra_retry_disposition',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*ExactObservedStatRuntimeExtraRetryAvailable)(?=.*exactObservedStatRuntimeFinalStandardAttempt)(?=.*exactObservedStatRuntimeExtraRetryCandidate\s*=\s*\(\s*\$exactSentinelRace)(?=.*exactObservedStatRuntimeExtraRetryEligible)(?=.*RETRY_EXACT_STAT_RUNTIME)(?=.*exact_wire_observed_STAT_RUNTIME_extra_retry)(?=.*exact_wire_observed_STAT_RUNTIME_extra_retry_exhausted)(?=.*AttemptNumber\s*-eq\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*exact_observed_stat_runtime_extra_retry_selected)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_exact_active_stat_runtime_retry_disposition',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*exactActiveVehicleFailureSet)(?=.*failedVehicleNames\.Count\s*-eq\s*4)(?=.*failedVehicleNames\s+-ccontains\s*''d722_stable'')(?=.*failedVehicleNames\s+-ccontains\s*''d722_rf22_reconciled'')(?=.*failedVehicleNames\s+-ccontains\s*''pgq'')(?=.*failedVehicleNames\s+-ccontains\s*''pga'')(?=.*exactActiveSchedulerState)(?=.*pgq)(?=.*pga)(?=.*prq)(?=.*ptq)(?=.*pvs1)(?=.*d7pb)(?=.*-eq\s*\[uint64\]1)(?=.*-eq\s*\[uint64\]0)(?=.*exactKnownEvent)(?=.*STAT_RUNTIME)(?=.*65535)(?=.*932)(?=.*pvsys)(?=.*pvcomp)(?=.*silentD722DeltaOne)(?=.*silentPvokDeltaOne)(?=.*silentSameBoot)(?=.*silentOfficialReconciled)(?=.*silentCurrentAheadOne)(?=.*silentObserverCountersAligned)(?=.*silentObserverExact)(?=.*silentPvmsFresh)(?=.*silentRelatedErrorZero)(?=.*exactActiveStatRuntimeRace)(?=.*retryCandidate\s*=\s*\(\$exactSentinelRace\s+-or\s*\$exactActiveStatRuntimeRace\s+-or)(?=.*exact_active_STAT_RUNTIME_m0_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_silent_inflight_stat_runtime_retry_disposition',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*OfficialGround)(?=.*exact_silent_inflight_STAT_RUNTIME_race)(?=.*M0Events)(?=.*events\.Count\s*-eq\s*0)(?=.*CausalGate\.valid)(?=.*failedVehicleNames\.Count\s*-eq\s*2)(?=.*failedVehicleNames\s+-ccontains\s*''d722_stable'')(?=.*failedVehicleNames\s+-ccontains\s*''d722_rf22_reconciled'')(?=.*STAT_RUNTIME)(?=.*65535)(?=.*932)(?=.*pvsys)(?=.*pvcomp)(?=.*pvms)(?=.*d722)(?=.*rf22)(?=.*pvok)(?=.*pvs1)(?=.*d7pb)(?=.*pgq)(?=.*pga)(?=.*prq)(?=.*ptq)(?=.*related_error_zero)(?=.*observer_exact)(?=.*delta_one)(?=.*same_boot)(?=.*parserClean)(?=.*heartbeatClean)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*REJECT)(?=.*retry_eligible)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_exact_late_queued_stat_runtime_retry_disposition',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*exactSilentQueuedVehicleFailureSet[\s\S]*failedVehicleNames\.Count\s*-eq\s*3[\s\S]*failedVehicleNames\s+-ccontains\s*''d722_stable''[\s\S]*failedVehicleNames\s+-ccontains\s*''d722_rf22_reconciled''[\s\S]*failedVehicleNames\s+-ccontains\s*''pgq'')(?=.*officialPgq[\s\S]*OfficialVehicle[\s\S]*pgq)(?=.*officialPga[\s\S]*OfficialVehicle[\s\S]*pga)(?=.*officialPrq[\s\S]*OfficialVehicle[\s\S]*prq)(?=.*officialPtq[\s\S]*OfficialVehicle[\s\S]*ptq)(?=.*officialPvs1[\s\S]*OfficialVehicle[\s\S]*pvs1)(?=.*exactSilentQueuedOfficialSchedulerState)(?=.*officialPgq\.found[\s\S]*officialPgq\.value\s*-eq\s*\[uint64\]0[\s\S]*officialPga\.found[\s\S]*officialPga\.value\s*-eq\s*\[uint64\]0[\s\S]*officialPrq\.found[\s\S]*officialPrq\.value\s*-eq\s*\[uint64\]0[\s\S]*officialPtq\.found[\s\S]*officialPtq\.value\s*-eq\s*\[uint64\]0[\s\S]*officialPvs1\.found[\s\S]*officialPvs1\.value\s*-eq\s*\[uint64\]0)(?=.*exactSilentQueuedSchedulerState)(?=.*pgq\.found[\s\S]*pgq\.value\s*-eq\s*\[uint64\]1)(?=.*pga\.found[\s\S]*pga\.value\s*-eq\s*\[uint64\]0)(?=.*prq\.found[\s\S]*prq\.value\s*-eq\s*\[uint64\]0)(?=.*ptq\.found[\s\S]*ptq\.value\s*-eq\s*\[uint64\]0)(?=.*pvs1\.found[\s\S]*pvs1\.value\s*-eq\s*\[uint64\]0)(?=.*currentD7pb\.found[\s\S]*currentD7pb\.value\s*-eq\s*\[uint64\]0)(?=.*exactLateQueuedStatRuntimeRace[\s\S]*CausalGate\.valid[\s\S]*events\.Count\s*-eq\s*0[\s\S]*exactSilentQueuedVehicleFailureSet[\s\S]*exactSilentQueuedSchedulerState)(?=.*silentSameBoot)(?=.*silentOfficialReconciled)(?=.*silentCurrentAheadOne)(?=.*silentD722DeltaOne)(?=.*silentPvokDeltaOne)(?=.*silentObserverCountersAligned)(?=.*silentObserverExact)(?=.*silentPvmsFresh)(?=.*silentRelatedErrorZero)(?=.*retryCandidate[\s\S]*exactLateQueuedStatRuntimeRace)(?=.*exact_late_queued_STAT_RUNTIME_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_silent_d7pb_zero_and_partial_partition',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*officialD7pb\s*=\s*Get-SnapshotUInt64[\s\S]*OfficialVehicle[\s\S]*d7pb)(?=.*currentD7pb\s*=\s*Get-SnapshotUInt64[\s\S]*PreRequestVehicle[\s\S]*d7pb)(?=.*silentD7pbEmpty[\s\S]*\[uint64\]\$officialD7pb\.value\s*-eq\s*\[uint64\]0[\s\S]*\[uint64\]\$currentD7pb\.value\s*-eq\s*\[uint64\]0)(?=.*silentPartialD7pbBounded[\s\S]*\[uint64\]\$officialD7pb\.value\s*-eq\s*\[uint64\]0[\s\S]*\[uint64\]\$currentD7pb\.value\s*-ge\s*\[uint64\]1[\s\S]*\[uint64\]\$currentD7pb\.value\s*-le\s*\[uint64\]279)(?=.*exactSilentVehicleFailureSet[\s\S]*failedVehicleNames\.Count\s*-eq\s*2)(?=.*exactSilentPartialVehicleFailureSet[\s\S]*failedVehicleNames\.Count\s*-eq\s*3[\s\S]*failedVehicleNames\s+-ccontains\s*''d7pb_empty'')(?=.*exactSilentInFlightStatRuntimeRace[\s\S]*silentD7pbEmpty)(?=.*exactPreM0TailStatRuntimeRace[\s\S]*silentPartialD7pbBounded[\s\S]*preM0TailRaceEvidence\.valid)(?=.*silentSameBoot)(?=.*silentOfficialReconciled)(?=.*silentCurrentAheadOne)(?=.*silentD722DeltaOne)(?=.*silentPvokDeltaOne)(?=.*silentObserverCountersAligned)(?=.*silentObserverExact)(?=.*silentPvmsFresh)(?=.*silentRelatedErrorZero)'),
      @('scoped_exact_pre_m0_tail_stat_runtime_race_evidence',
        $preM0TailRaceFunction,
        '(?s)\A(?=.*PreM0TailEvidence)(?=.*OfficialVehicle)(?=.*PreRequestVehicle)(?=.*M0GroundRawOffset)(?=.*M0Events)(?=.*completed_duration)(?=.*requested_milliseconds)(?=.*3000)(?=.*raw_start_offset)(?=.*raw_end_offset)(?=.*integrity[\s\S]*valid)(?=.*events[\s\S]*Count\s*-eq\s*1)(?=.*crc_valid[\s\S]*-eq\s*\$true)(?=.*message_id[\s\S]*-eq\s*22)(?=.*classification[\s\S]*known_STAT_RUNTIME_sentinel)(?=.*anomaly_classes[\s\S]*Count\s*-eq\s*0)(?=.*param_id_hex)(?=.*param_value_hex)(?=.*Get-SnapshotString[\s\S]*pvid)(?=.*Get-SnapshotString[\s\S]*pvval)(?=.*Get-SnapshotUInt64[\s\S]*pvidx)(?=.*Get-SnapshotUInt64[\s\S]*pvcnt)(?=.*Get-SnapshotUInt64[\s\S]*pvtype)(?=.*Get-SnapshotUInt64[\s\S]*pvseq)(?=.*Get-SnapshotUInt64[\s\S]*pvsys)(?=.*Get-SnapshotUInt64[\s\S]*pvcomp)(?=.*system_id[\s\S]*component_id)(?=.*sequence[\s\S]*pvseq)(?=.*raw_start_offset[\s\S]*-ge[\s\S]*PreM0TailEvidence[\s\S]*raw_start_offset)(?=.*raw_end_offset_exclusive[\s\S]*-le[\s\S]*PreM0TailEvidence[\s\S]*raw_end_offset)(?=.*raw_end_offset_exclusive[\s\S]*-eq[\s\S]*M0GroundRawOffset)(?=.*M0Events[\s\S]*Count\s*-eq\s*0)(?=.*classification\s*=\s*''exact_pre_M0_tail_STAT_RUNTIME_race'')(?=.*valid)(?=.*checks)'),
      @('scoped_exact_pre_m0_tail_r7_heartbeat_suffix_evidence',
        $preM0TailRaceFunction,
        '(?s)\A(?=.*valid_events)(?=.*validEventsAvailable)(?=.*targetMirrorCount[\s\S]*-eq\s*1)(?=.*message_id[\s\S]*-eq\s*22)(?=.*payload_length[\s\S]*-eq\s*25)(?=.*raw_start_offset[\s\S]*event\.raw_start_offset)(?=.*raw_end_offset_exclusive[\s\S]*event\.raw_end_offset_exclusive)(?=.*trailingMessageId[\s\S]*-ne\s*0)(?=.*trailingSystemId[\s\S]*-ne\s*1)(?=.*trailingComponentId[\s\S]*-ne\s*1)(?=.*trailingPayloadLength[\s\S]*-ne\s*9)(?=.*trailingFrameVersion[\s\S]*-ne\s*2)(?=.*trailingSigned)(?=.*expectedTrailingRawStart)(?=.*trailingRawEnd\.Value\s*-[\s\S]*trailingRawStart\.Value\s*-ne\s*21)(?=.*trailingPhase[\s\S]*tailProducerPhase)(?=.*trailingEpoch[\s\S]*tailProducerEpoch)(?=.*trailingHeartbeatCount\s*-ge\s*1)(?=.*expectedTrailingRawStart\s*-eq\s*\[long\]\$M0GroundRawOffset)(?=.*contiguous_vehicle_heartbeat_chain)(?=.*boundaryExact\s*=\s*\$true)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_exact_observed_m0_stat_runtime_partial_d7_evidence',
        $observedPartialRaceFunction,
        '(?s)\A(?=.*CausalGate)(?=.*PreRequestVehicle)(?=.*M0GroundRawOffset)(?=.*M0GateEndGroundRawOffset)(?=.*M0Events)(?=.*events\.Count\s*-eq\s*1)(?=.*eventSchemaExact)(?=.*crc_valid)(?=.*message_id)(?=.*payload_length)(?=.*25)(?=.*known_STAT_RUNTIME_sentinel)(?=.*anomaly_classes)(?=.*ExpectedStatRuntimeIdHex)(?=.*param_value_hex)(?=.*param_value_bits_hex)(?=.*pvid)(?=.*pvval)(?=.*pvidx)(?=.*pvcnt)(?=.*pvtype)(?=.*pvseq)(?=.*pvsys)(?=.*pvcomp)(?=.*65535)(?=.*932)(?=.*system_id)(?=.*component_id)(?=.*capture_scope[\s\S]*pre_request_m0)(?=.*producer_phase[\s\S]*M0_pre_request_clean_5s)(?=.*producer_epoch[\s\S]*M0_pre_request_clean_5s)(?=.*rawStart\s*-ge\s*\$M0GroundRawOffset)(?=.*rawEnd\s*-le\s*\$M0GateEndGroundRawOffset)(?=.*rawEnd\s*-\s*\$rawStart\)\s*-eq\s*37)(?=.*target_param_value_count)(?=.*parser_buffer_empty)(?=.*m0_epoch_completed)(?=.*veto_event_count)(?=.*stale_param_value_count)(?=.*stale_generic_count)(?=.*known_stat_runtime_sentinel_count)(?=.*m0_event_count)(?=.*m0_veto_events)(?=.*causalM0RawStart[\s\S]*M0GroundRawOffset)(?=.*causalM0RawEnd[\s\S]*M0GateEndGroundRawOffset)(?=.*classification=''exact_observed_STAT_RUNTIME_partial_D7_race'')(?=.*fixture_write_count=0)'),
      @('scoped_pre_request_exact_observed_partial_d7_retry_only',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*M0GateEndGroundRawOffset)(?=.*Test-ExactObservedM0StatRuntimePartialD7Race[\s\S]*-CausalGate\s+\$CausalGate[\s\S]*-PreRequestVehicle\s+\$PreRequestVehicle[\s\S]*-M0GroundRawOffset\s+\$M0GroundRawOffset[\s\S]*-M0GateEndGroundRawOffset\s+\$M0GateEndGroundRawOffset[\s\S]*-M0Events\s+\$events)(?=.*exactObservedStatRuntimePartialD7Race)(?=.*exactKnownEvent)(?=.*exactSilentPartialVehicleFailureSet)(?=.*sentinelDeltaExact)(?=.*silentPartialD7pbBounded)(?=.*exactSilentQueuedOfficialSchedulerState)(?=.*silentNonParserQueueEmpty)(?=.*silentSameBoot)(?=.*silentOfficialReconciled)(?=.*silentCurrentAheadOne)(?=.*silentD722DeltaOne)(?=.*silentPvokDeltaOne)(?=.*silentObserverCountersAligned)(?=.*silentObserverExact)(?=.*silentPvmsFresh)(?=.*exactActiveErrorZero)(?=.*observedPartialEventEvidence\.valid)(?=.*retryCandidate[\s\S]*exactObservedStatRuntimePartialD7Race)(?=.*exact_observed_STAT_RUNTIME_partial_D7_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*retry_exhausted)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_exact_post_m0_vehicle_snapshot_stat_runtime_partial_d7_evidence',
        $postM0SnapshotRaceFunction,
        '(?s)\A(?=.*CausalGate)(?=.*OfficialVehicle)(?=.*OfficialGround)(?=.*PreRequestVehicle)(?=.*M0Capture)(?=.*DiagnosticEndBarrier)(?=.*M0Events)(?=.*events\.Count\s*-eq\s*1)(?=.*known_STAT_RUNTIME_sentinel)(?=.*crcValid)(?=.*messageExact)(?=.*payloadLengthExact)(?=.*valueExact)(?=.*tupleExact)(?=.*sourceExact)(?=.*sequenceExact)(?=.*capture_scope[\s\S]*pre_request_m0)(?=.*producer_phase[\s\S]*snapshotName)(?=.*producer_epoch[\s\S]*snapshotName)(?=.*requested_milliseconds[\s\S]*5000)(?=.*completed_duration)(?=.*deadline_reached)(?=.*start_barrier)(?=.*m0StartBarrierActive)(?=.*m0StartRawOffset)(?=.*m0StartBoundaryElapsed)(?=.*capture_start_barrier)(?=.*diagnosticRawStart)(?=.*DiagnosticEndBarrier[\s\S]*diagnosticRawEnd)(?=.*rawStart\s*-ge\s*\[long\]\$diagnosticRawStart\.value)(?=.*rawEnd\s*-le\s*\[long\]\$diagnosticRawEnd\.value)(?=.*rawEnd\s*-\s*\$rawStart\)\s*-eq\s*37)(?=.*eventElapsedMs\s*-gt\s*\[double\]\$m0Finished\.value)(?=.*eventElapsedMs\s*-ge\s*\[double\]\$snapshotStarted\.value)(?=.*eventElapsedMs\s*-le\s*\[double\]\$snapshotFinished\.value)(?=.*decision_scope)(?=.*fresh_m0_only)(?=.*readiness_events_audit_only)(?=.*m0_veto_events)(?=.*causalM0RawStart\.value\s*-eq\s*\[long\]\$m0StartRawOffset\.value)(?=.*causalM0RawEnd\.value\s*-eq\s*\[long\]\$diagnosticRawStart\.value)(?=.*classification\s*=\s*''exact_post_M0_vehicle_snapshot_STAT_RUNTIME_partial_D7_race'')(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_post_m0_vehicle_snapshot_retry_is_exact_and_bounded',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*exactPostM0SnapshotVehicleFailureSet[\s\S]*failedVehicleNames\.Count\s*-eq\s*4[\s\S]*failedVehicleNames\s+-ccontains\s*''d722_stable''[\s\S]*failedVehicleNames\s+-ccontains\s*''d722_rf22_reconciled''[\s\S]*failedVehicleNames\s+-ccontains\s*''pgq''[\s\S]*failedVehicleNames\s+-ccontains\s*''d7pb_empty'')(?=.*Test-ExactPostM0VehicleSnapshotStatRuntimePartialD7Race)(?=.*exactPostM0SnapshotEventEvidence\.valid)(?=.*official[\s\S]*idle)(?=.*silentOfficialReconciled)(?=.*silentD722DeltaOne)(?=.*silentPvokDeltaOne)(?=.*pgq[\s\S]*-eq\s*\[uint64\]1)(?=.*pga[\s\S]*-eq\s*\[uint64\]0)(?=.*prq[\s\S]*-eq\s*\[uint64\]0)(?=.*ptq[\s\S]*-eq\s*\[uint64\]0)(?=.*pvs1[\s\S]*-eq\s*\[uint64\]0)(?=.*d7pb[\s\S]*-ge\s*\[uint64\]1[\s\S]*-le\s*\[uint64\]279)(?=.*exactActiveErrorZero)(?=.*retryCandidate[\s\S]*exactPostM0VehicleSnapshotStatRuntimeRace)(?=.*exact_post_M0_vehicle_snapshot_STAT_RUNTIME_partial_D7_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_post_m0_vehicle_snapshot_end_barrier_and_disposition_plumbed_without_wait_or_write',
        $officialPreRequestGateFunction,
        '(?s)\A(?=.*\$preRequestVehicle\s*=\s*Invoke-SnapshotQuery[\s\S]*Invoke-PumpPair(?:(?!Invoke-CaptureInterval|Start-Sleep|Wait-)[\s\S])*?\$postM0DiagnosticEndBarrier\s*=\s*Set-ReaderCaptureContext\s*`?[\r\n\s]*-Phase\s+\$postM0DiagnosticSealPhase\s+-Epoch\s+\$postM0DiagnosticSealPhase)(?=.*postM0DiagnosticSealPhase[\s\S]*pre_request_vehicle_\{0\}_sealed)(?=.*Get-PreRequestAttemptDisposition[\s\S]*-M0Capture\s+\$m0Capture[\s\S]*-DiagnosticEndBarrier\s+\$postM0DiagnosticEndBarrier)(?=.*m0_capture\s*=\s*\$m0Capture)(?=.*post_m0_diagnostic_end_barrier\s*=\s*\$postM0DiagnosticEndBarrier)(?=.*-AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs)(?=.*deadline_elapsed_ms\s*=\s*\$DeadlineElapsedMs)(?=.*deadline_extended\s*=\s*\$false)(?![\s\S]*Write-ExactRequestOnce)'),
      @('scoped_m0_broker_end_barrier_plumbed_without_extra_wait',
        ($snapshotQueryFunction + [Environment]::NewLine +
          $m0GateFunction + [Environment]::NewLine +
          $officialPreRequestGateFunction),
        '(?s)(?=.*queryStartBarrier\s*=\s*Set-ReaderCaptureContext\s+-Phase\s+\$Name)(?=.*capture_start_barrier\s*=\s*\$queryStartBarrier)(?=.*m0_ground_raw_offset\s*=\s*\$M0GroundRawOffset)(?=.*m0_gate_end_ground_raw_offset\s*=\s*\$M0GateEndGroundRawOffset)(?=.*Test-M0CausalGate[\s\S]*-M0GroundRawOffset[\s\S]*-M0GateEndGroundRawOffset[\s\S]*capture_start_barrier\.ground_raw_offset_exclusive)(?=.*Get-PreRequestAttemptDisposition[\s\S]*-M0GroundRawOffset[\s\S]*-M0GateEndGroundRawOffset[\s\S]*capture_start_barrier\.ground_raw_offset_exclusive)'),
      @('scoped_pre_request_exact_pre_m0_tail_partial_d7pb_retry_only',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*PreM0TailEvidence)(?=.*M0GroundRawOffset)(?=.*Test-ExactPreM0TailStatRuntimeRace[\s\S]*-PreM0TailEvidence\s+\$PreM0TailEvidence[\s\S]*-OfficialVehicle\s+\$OfficialVehicle[\s\S]*-PreRequestVehicle\s+\$PreRequestVehicle[\s\S]*-M0GroundRawOffset\s+\$M0GroundRawOffset[\s\S]*-M0Events\s+\$events)(?=.*preM0TailRaceEvidence)(?=.*exactPreM0TailStatRuntimeRace[\s\S]*preM0TailRaceEvidence\.valid)(?=.*retryCandidate\s*=\s*\([\s\S]*\$exactPreM0TailStatRuntimeRace)(?=.*if\s*\(\[bool\]\$CausalGate\.valid\s+-and\s+\[bool\]\$PreRequestVehicleGate\.valid\)[\s\S]*\$action\s*=\s*''ACCEPT'')(?=.*elseif\s*\(\$retryEligible\)[\s\S]*\$action\s*=\s*''RETRY'')(?=.*exact_pre_M0_tail_STAT_RUNTIME_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_r7_heartbeat_gap_prior_partial_retry_only',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*priorAndCurrentPartialD7pbBounded[\s\S]*officialD7pb\.value\s*-ge\s*\[uint64\]1[\s\S]*officialD7pb\.value\s*-le\s*\[uint64\]279[\s\S]*currentD7pb\.value\s*-ge\s*\[uint64\]1[\s\S]*currentD7pb\.value\s*-le\s*\[uint64\]279)(?=.*exactPreM0TailHeartbeatGapPriorPartialD7Race[\s\S]*CausalGate\.valid[\s\S]*exactSilentPartialVehicleFailureSet[\s\S]*priorAndCurrentPartialD7pbBounded[\s\S]*exactSilentQueuedOfficialSchedulerState[\s\S]*silentOfficialReconciled[\s\S]*silentCurrentAheadOne[\s\S]*silentD722DeltaOne[\s\S]*silentPvokDeltaOne[\s\S]*silentObserverExact[\s\S]*silentNonParserQueueEmpty[\s\S]*silentRelatedErrorZero[\s\S]*preM0TailRaceEvidence\.valid[\s\S]*contiguous_vehicle_heartbeat_chain[\s\S]*target_valid_event_mirror_exact[\s\S]*trailing_heartbeat_chain_exact[\s\S]*trailing_heartbeat_count\s*-ge\s*1)(?=.*retryCandidate[\s\S]*exactPreM0TailHeartbeatGapPriorPartialD7Race)(?=.*exact_pre_M0_tail_STAT_RUNTIME_heartbeat_gap_prior_partial_D7_race)(?=.*AttemptNumber\s*-lt\s*\$MaxAttempts)(?=.*RetryBudgetAvailable)(?=.*RETRY)(?=.*REJECT)(?=.*fixture_write_count\s*=\s*0)'),
      @('scoped_pre_request_active_m0_requires_empty_d7_parser',
        $preRequestDispositionFunction,
        '(?s)\A(?=.*exactActiveSchedulerState[\s\S]*d7pb\.found[\s\S]*\[uint64\]\$d7pb\.value\s*-eq\s*\[uint64\]0)(?=.*exactActiveStatRuntimeRace[\s\S]*exactActiveSchedulerState)(?=.*exact_active_STAT_RUNTIME_m0_race)(?=.*RETRY)(?=.*REJECT)'),
      @('scoped_official_pre_request_gate_bounded_stable_pair_promotion_retry',
        $officialPreRequestGateFunction,
        '(?s)(?=.*DeadlineElapsedMs)(?=.*InitialVehicleSnapshot)(?=.*InitialGroundSnapshot)(?=.*MaxAttempts\s*=\s*3)(?=.*M0_pre_request_clean_5s)(?=.*Invoke-SnapshotQuery)(?=.*Test-PreRequestVehicleGate)(?=.*Test-M0CausalGate)(?=.*Get-PreRequestAttemptDisposition)(?=.*Invoke-PreBaselineBacklogDrainGate)(?=.*Test-PreRequestRecoveryBacklogPairPromotion)(?=.*AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs)(?=.*deadline_extended\s*=\s*\$false)(?=.*fixture_write_count\s*=\s*0)(?=.*retry_exhausted)(?=.*latest_complete_vehicle_snapshot)(?=.*final_vehicle_snapshot)(?=.*final_ground_snapshot)(?=.*attempts)'),
      @('scoped_official_pre_request_gate_seals_pre_m0_tail_at_ground_barrier',
        $officialPreRequestGateFunction,
        ('(?s)\A' +
        '(?=.*\$GroundParser\.Enabled\s*=\s*\$false[\s\S]*' +
          'Reset-MavlinkAnalysis\s+-Parser\s+\$GroundParser[\s\S]*' +
          'preM0TailStartBarrier\s*=\s*Set-ReaderCaptureContext[\s\S]*' +
          'pre_request_attempt_[\s\S]*recovery_3s[\s\S]*' +
          'preM0TailStartRawOffset\s*=\s*\[long\]' +
          '\$preM0TailStartBarrier\.ground_raw_offset_exclusive[\s\S]*' +
          'ParamList\.capture_scope\s*=\s*''pre_request_readiness''[\s\S]*' +
          '\$GroundParser\.Enabled\s*=\s*\$true[\s\S]*' +
          'Invoke-CaptureInterval\s+-Milliseconds\s+3000[\s\S]*' +
          'preM0TailEndBarrier\s*=\s*Set-ReaderCaptureContext[\s\S]*' +
          'M0_pre_request_clean_5s[\s\S]*' +
          'preM0TailEndRawOffset\s*=\s*\[long\]' +
          '\$preM0TailEndBarrier\.ground_raw_offset_exclusive[\s\S]*' +
          '\$GroundParser\.Enabled\s*=\s*\$false[\s\S]*' +
          'Get-ParserIntegrity\s+-Parser\s+\$GroundParser[\s\S]*' +
          'ParamList\.events\.ToArray\(\)[\s\S]*' +
          'ValidEvents\.ToArray\(\)[\s\S]*' +
          'preM0TailEvidence\s*=\s*\[pscustomobject\]\[ordered\]@\{)' +
        '(?=.*requested_milliseconds\s*=\s*3000)' +
        '(?=.*capture\s*=\s*\$recoveryCapture)' +
        '(?=.*completed_duration\s*=\s*\[bool\]' +
          '\$recoveryCapture\.completed_duration)' +
        '(?=.*raw_start_offset\s*=\s*\$preM0TailStartRawOffset)' +
        '(?=.*raw_end_offset\s*=\s*\$preM0TailEndRawOffset)' +
        '(?=.*integrity\s*=)(?=.*events\s*=)(?=.*valid_events\s*=)' +
        '(?=.*ground_raw_offset\s*=\s*\[long\]' +
          '\$preM0TailEndRawOffset)' +
        '(?=.*Reset-MavlinkAnalysis\s+-Parser\s+\$GroundParser[\s\S]*' +
          'ParamList\.capture_scope\s*=\s*''pre_request_m0''[\s\S]*' +
          '\$GroundParser\.Enabled\s*=\s*\$true[\s\S]*' +
          'Invoke-CaptureInterval\s+-Milliseconds\s+5000)' +
        '(?=.*Get-PreRequestAttemptDisposition[\s\S]*' +
          '-PreM0TailEvidence\s+\$preM0TailEvidence[\s\S]*' +
          '-M0GroundRawOffset\s+\(?(?:\[long\])?' +
          '\$m0\.ground_raw_offset\)?)' +
        '(?=.*m0_events\s*=\s*\$M0Events)' +
        '(?=.*pre_m0_tail_evidence\s*=\s*\$preM0TailEvidence)')),
      @('scoped_pre_request_silent_retry_uses_verified_stable_pair_promotion',
        $officialPreRequestGateFunction,
        '(?s)(?=.*Get-PreRequestAttemptDisposition)(?=.*OfficialGround\s+\$officialGround)(?=.*action\s+-cne\s+''RETRY'')(?=.*Invoke-PreBaselineBacklogDrainGate)(?=.*AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs)(?=.*Test-PreRequestRecoveryBacklogPairPromotion)(?=.*officialVehicle\s*=\s*\$recoveryPairPromotion\.selected_vehicle_snapshot)(?=.*officialGround\s*=\s*\$recoveryPairPromotion\.selected_ground_snapshot)(?=.*skipNextRecoveryCapture\s*=\s*\$true)(?=.*continue)'),
      @('scoped_readiness_window_primary_hb_and_clean_parser',
        $readinessWindowFunction,
        'Get-HeartbeatWindowMetrics[\s\S]*ParserIntegrity\.valid[\s\S]*heartbeat\.valid[\s\S]*heartbeat\.count\s+-ge\s+2'),
      @('scoped_passive_candidate_primary_hb_and_clean_parser',
        $passiveCandidateFunction,
        'Capture[\s\S]*Idle[\s\S]*GroundRawStartOffset[\s\S]*GroundRawEndOffset[\s\S]*started_elapsed_ms[\s\S]*finished_elapsed_ms[\s\S]*Get-HeartbeatWindowMetrics[\s\S]*completed_duration[\s\S]*ParserIntegrity\.valid[\s\S]*heartbeat\.valid[\s\S]*heartbeat\.count\s+-ge\s+2[\s\S]*candidate[\s\S]*sync_invalid'),
      @('scoped_passive_candidate_full_pipeline_budget',
        $passiveDecisionFunction,
        'SnapshotTimeoutSeconds[\s\S]*passiveWindowMs\s*=\s*5000[\s\S]*freshWindowMs\s*=\s*5000[\s\S]*requiredRemainingMs\s*=\s*\$passiveWindowMs\s*\+\s*\$snapshotTimeoutMs\s*\+[\s\S]*\$freshWindowMs\s*\+[\s\S]*ReadinessVehicleBReserveMs[\s\S]*required_remaining_ms[\s\S]*can_start_full_pipeline[\s\S]*timed_out'),
      @('scoped_matcher_snapshot_preserves_pending_state',
        $matcherSnapshotFunction,
        'MatcherCandidate\.ToArray\(\)[\s\S]*pending_byte_count[\s\S]*pending_bytes_hex[\s\S]*MatcherStartOffset[\s\S]*MatcherOverflows[\s\S]*TaggedLines\.Count[\s\S]*RawBytes'),
      @('scoped_sync_invalid_suppressed_snapshot_schema',
        $suppressedSnapshotFunction,
        '\[object\[\]\]\$responses\s*=\s*\[object\[\]\]@\(\)[\s\S]*NOT_RUN_SYNC_INVALID[\s\S]*query_count\s*=\s*0[\s\S]*query_attempt_count\s*=\s*0[\s\S]*responses\s*=\s*\$responses[\s\S]*matcher_at_latch[\s\S]*matcher_at_suppression'),
      @('scoped_post_plan_includes_baseline_sync_invalid',
        $postDiagnosticPlanFunction,
        '(?s)(?=.*BaselinePairGate)(?=.*baselineSyncInvalid)(?=.*baseline_sync_invalid)(?=.*anySyncInvalid)(?=.*sources)(?=.*Add\(''baseline''\))(?=.*run_ground)(?=.*run_vehicle)'),
      @('scoped_post_diagnostic_sync_invalid_matrix',
        $postDiagnosticPlanFunction,
        'DataPlaneReadiness[\s\S]*BacklogDrainGate[\s\S]*readiness_sync_invalid[\s\S]*backlog_sync_invalid[\s\S]*any_sync_invalid[\s\S]*run_ground\s*=\s*\(-not\s+\$anySyncInvalid\)[\s\S]*run_vehicle\s*=\s*\(-not\s+\$anySyncInvalid\)[\s\S]*NOT_RUN_SYNC_INVALID'),
      @('scoped_param_event_copy_is_lossless_bounded',
        $paramEventCopyFunction,
        'SourceState\.events\.ToArray\(\)[\s\S]*Destination\.Count[\s\S]*MaxParamValueEvidenceEvents[\s\S]*refusing truncation[\s\S]*Destination\.Add'),
      @('scoped_parser_epoch_close_idempotent_harvest_reset',
        $parserEpochFunction,
        'Epoch\.closed[\s\S]*return\s+\$Epoch\.result[\s\S]*Enabled\s*=\s*\$false[\s\S]*Copy-ParamListEventsToEvidence[\s\S]*Get-ParserIntegrity[\s\S]*heartbeat_events[\s\S]*Reset-MavlinkAnalysis[\s\S]*Epoch\.closed\s*=\s*\$true[\s\S]*Epoch\.result'),
      @('scoped_matcher_clean_exact_pending_bytes',
        $matcherCleanFunction,
        'Get-CaptureMatcherSnapshot[\s\S]*pending_byte_count\s+-eq\s+0[\s\S]*pending_start_offset\s+-eq\s+-1[\s\S]*overflow_count[\s\S]*ExpectedOverflowCount[\s\S]*valid'),
      @('scoped_expected_A_uses_complete_B_only',
        $expectedAFunction,
        'LastCompleteVehicleB[\s\S]*status[\s\S]*COMPLETE[\s\S]*q_uint32[\s\S]*Get-NextQueryId'),
      @('scoped_pump_pair_to_idle_bounded',
        $pumpToIdleFunction,
        'AbsoluteDeadlineElapsedMs[\s\S]*while[\s\S]*TotalMilliseconds\s+-lt[\s\S]*AbsoluteDeadlineElapsedMs[\s\S]*Invoke-PumpPair[\s\S]*activityObserved\s*=\s*\(\$read\s+-gt\s+0\)[\s\S]*if\s*\(\s*-not\s+\$activityObserved\s*\)[\s\S]*idle\s*=\s*\$true[\s\S]*iteration_count[\s\S]*deadline_reached'),
      @('scoped_sync_invalid_continuation_schema',
        $syncContinuationFunction,
        'MatcherAtLatch[\s\S]*BeforeFooterPump[\s\S]*AfterFooterPump[\s\S]*DiagnosticWriteCountBefore[\s\S]*DiagnosticWriteCountAfter[\s\S]*writeDelta[\s\S]*valid[\s\S]*diagnostic_write_count_delta'),
      @('scoped_sync_invalid_latch_freezes_response_matcher',
        $syncInvalidLatchFunction,
        'Role[\s\S]*Stage[\s\S]*Failure[\s\S]*Response[\s\S]*MatcherSnapshot[\s\S]*latched\s*=\s*\$true[\s\S]*matcher_at_latch'),
      @('scoped_snapshot_transition_fail_closed_state',
        $snapshotTransitionFunction,
        'Stage[\s\S]*Test-ReadinessSnapshotResponse[\s\S]*postQueryMatcherClean[\s\S]*if\s*\(-not\s+\$response\.valid\s+-or\s+-not\s+\$postQueryMatcherClean\)[\s\S]*New-ReadinessSyncInvalidLatch[\s\S]*next_complete_B[\s\S]*subsequent_diagnostic_query_count\s*=\s*0[\s\S]*request_write_count\s*=\s*0[\s\S]*Stage\s+-eq\s+''B'''),
      @('scoped_suppressed_snapshot_text_exact',
        $snapshotTextFunction,
        'NOT_RUN_SYNC_INVALID query_count=0 query_attempt_count=0 reason=SYNC_INVALID`n'),
      @('scoped_readiness_device_ms_brackets_window',
        $readinessWindowFunction,
        'ReadinessDeviceMsToleranceMs[\s\S]*windowDurationMs[\s\S]*requiredDeviceMsDelta[\s\S]*deviceMsDelta[\s\S]*ms_brackets_window'),
      @('scoped_readiness_snapshot_response_exact',
        $readinessResponseFunction,
        'status[\s\S]*COMPLETE[\s\S]*query_count[\s\S]*write_timed_out[\s\S]*q_uint32[\s\S]*ExpectedQ[\s\S]*expected_q_exact[\s\S]*valid'),
      @('scoped_last_snapshot_only_valid_bracket',
        $readinessLastSnapshotFunction,
        'VehicleAResponse\.valid[\s\S]*VehicleBResponse\.valid[\s\S]*WindowAssessment\.valid[\s\S]*WithinDeadline[\s\S]*return\s+\$VehicleAfter[\s\S]*return\s+\$CurrentSnapshot'),
      @('scoped_live_readiness_repeats_fresh_5s_windows',
        $readinessGateFunction,
        'GateStartedElapsedMs[\s\S]*Get-ReadinessPassiveWindowDecision[\s\S]*data_plane_readiness_passive_window[\s\S]*Test-DataPlanePassiveCandidate[\s\S]*if\s*\(-not\s+\$passiveCandidate\.candidate\)[\s\S]*continue[\s\S]*readiness_vehicle_A[\s\S]*data_plane_readiness_window[\s\S]*Test-DataPlaneReadinessWindow[\s\S]*timed_out'),
      @('scoped_readiness_preserves_pre_request_param_values',
        $readinessGateFunction,
        'preRequestParamValueEvents[\s\S]*Complete-ReadinessParserEpoch[\s\S]*finally[\s\S]*Complete-ReadinessParserEpoch[\s\S]*pre_request_param_value_count[\s\S]*pre_request_param_value_events'),
      @('scoped_readiness_no_short_final_pipeline',
        $passiveDecisionFunction,
        'passiveWindowMs\s*=\s*5000[\s\S]*freshWindowMs\s*=\s*5000[\s\S]*requiredRemainingMs\s*=\s*\$passiveWindowMs\s*\+\s*\$snapshotTimeoutMs\s*\+[\s\S]*\$freshWindowMs\s*\+[\s\S]*ReadinessVehicleBReserveMs[\s\S]*can_start_full_pipeline\s*=\s*\(\$remainingMs\s+-ge\s+\$requiredRemainingMs\)[\s\S]*timed_out'),
      @('scoped_readiness_parser_cleanup_all_paths',
        $readinessGateFunction,
        'finally[\s\S]*GroundParser\.Enabled\s*=\s*\$false[\s\S]*Reset-MavlinkAnalysis'),
      @('scoped_readiness_raw_fsync_at_most_30s',
        $readinessGateFunction,
        'lastRawFlushElapsedMs[\s\S]*30000[\s\S]*VehicleState\.RawStream\.Flush\(\$true\)[\s\S]*GroundState\.RawStream\.Flush\(\$true\)'),
      @('scoped_readiness_candidate_forces_raw_fsync_before_A',
        $readinessGateFunction,
        'passiveCandidate\.candidate[\s\S]*Invoke-ReadinessRawFsyncBoundary[\s\S]*candidate_before_A[\s\S]*last_raw_flush_elapsed_ms[\s\S]*readiness_vehicle_A'),
      @('scoped_readiness_window_forces_raw_fsync_before_B',
        $readinessGateFunction,
        'Invoke-CaptureInterval[\s\S]*completed_duration[\s\S]*Invoke-ReadinessRawFsyncBoundary[\s\S]*window_before_B[\s\S]*last_raw_flush_elapsed_ms[\s\S]*readiness_vehicle_B'),
      @('scoped_readiness_vehicle_A_window_B',
        $readinessGateFunction,
        'data_plane_readiness_passive_window[\s\S]*passiveCandidate\.candidate[\s\S]*readiness_vehicle_A[\s\S]*Invoke-CaptureInterval[\s\S]*readiness_vehicle_B'),
      @('scoped_readiness_parser_enabled_A_window_B',
        $readinessGateFunction,
        'GroundParser\.Enabled\s*=\s*\$true[\s\S]*readiness_vehicle_A[\s\S]*Invoke-CaptureInterval[\s\S]*readiness_vehicle_B[\s\S]*bracketEpochResult\s*=\s*Complete-ReadinessParserEpoch'),
      @('scoped_readiness_invalid_assessment_returns_passive',
        $readinessGateFunction,
        'Test-DataPlaneReadinessWindow[\s\S]*if\s*\(\$windowRow\.valid\)[\s\S]*\$valid\s*=\s*\$true[\s\S]*else[\s\S]*phase\s*=\s*''passive_prefilter''[\s\S]*continue'),
      @('scoped_readiness_complete_B_seed_advances_before_assessment',
        $readinessGateFunction,
        '\$lastCompleteVehicleB\s*=\s*\$vehicleB[\s\S]*\$windowAssessment\s*=\s*Test-DataPlaneReadinessWindow'),
      @('scoped_readiness_sync_invalid_latches_matcher',
        $readinessGateFunction,
        'Get-CaptureMatcherSnapshot[\s\S]*New-ReadinessSyncInvalidLatch[\s\S]*vehicleSyncInvalid[\s\S]*matcher_at_latch[\s\S]*vehicle_sync_invalid'),
      @('scoped_readiness_A_reserves_window_and_B',
        $readinessGateFunction,
        'ReadinessVehicleBReserveMs[\s\S]*Get-DeadlineBoundSnapshotBudget[\s\S]*ReserveAfterMs[\s\S]*5000[\s\S]*vehicleBReserveMs[\s\S]*readiness_vehicle_A[\s\S]*AbsoluteDeadlineElapsedMs'),
      @('scoped_readiness_window_and_B_absolute_deadlines',
        $readinessGateFunction,
        'Invoke-CaptureInterval[\s\S]*AbsoluteDeadlineElapsedMs[\s\S]*readiness_vehicle_B[\s\S]*AbsoluteDeadlineElapsedMs'),
      @('scoped_snapshot_query_hard_absolute_deadline',
        $snapshotQueryFunction,
        'AbsoluteDeadlineElapsedMs[\s\S]*effectiveDeadlineElapsedMs[\s\S]*TotalMilliseconds\s+-ge\s+\$effectiveDeadlineElapsedMs[\s\S]*remainingMs[\s\S]*Start-Sleep'),
      @('scoped_snapshot_query_successful_write_counter',
        $snapshotQueryFunction,
        'Serial\.Write\(\$Command,\s*0,\s*\$Command\.Length\)[\s\S]{0,100}\+\+\$script:DiagnosticQueryWriteCount[\s\S]*Serial\.Write\(\$Command,\s*0,\s*\$Command\.Length\)[\s\S]{0,100}\+\+\$script:DiagnosticQueryWriteCount'),
      @('scoped_snapshot_write_timeout_clamped_and_restored',
        $snapshotQueryFunction,
        'Get-DeadlineBoundWritePlan[\s\S]*originalWriteTimeout[\s\S]*WriteTimeout\s*=\s*\[int\]\$writePlan\.write_timeout_ms[\s\S]*catch\s*\[System\.TimeoutException\][\s\S]*finally[\s\S]*WriteTimeout\s*=\s*\$originalWriteTimeout'),
      @('scoped_absolute_snapshot_omits_unbounded_flush',
        $snapshotQueryFunction,
        'if\s*\(\$null\s+-ne\s+\$AbsoluteDeadlineElapsedMs\)[\s\S]*base_stream_flush_allowed[\s\S]*\}\s*else\s*\{[\s\S]*BaseStream\.Flush\(\)[\s\S]*flush_skipped_for_absolute_deadline'),
      @('scoped_capture_interval_hard_absolute_deadline',
        $captureIntervalFunction,
        'AbsoluteDeadlineElapsedMs[\s\S]*TotalMilliseconds[\s\S]*completedDuration[\s\S]*deadlineReached[\s\S]*completed_duration[\s\S]*deadline_reached'),
      @('scoped_deadline_budget_double_ms_no_rounding',
        $deadlineBudgetFunction,
        'double[\s\S]*deadlineElapsedMs[\s\S]*ReserveAfterMs[\s\S]*configuredTimeoutMs[\s\S]*budget_ms[\s\S]*can_query'),
      @('scoped_deadline_write_plan_margin',
        $deadlineWriteFunction,
        'double[\s\S]*RemainingMs[\s\S]*ConfiguredWriteTimeoutMs[\s\S]*MarginMs[\s\S]*Floor[\s\S]*write_timeout_ms[\s\S]*can_write'),
      @('scoped_readiness_no_ground_diagnostic_query',
        $readinessGateFunction,
        'VehicleCommand[\s\S]*readiness_vehicle_A[\s\S]*readiness_vehicle_B'),
      @('scoped_param_diagnostics_nested_arrays_typed',
        $paramDiagnosticFunction,
        '\[object\[\]\]\$officialEvents\s*=\s*\[object\[\]\]@\(\)[\s\S]*\[object\[\]\]\$OfficialState\.events\.ToArray\(\)[\s\S]*\[object\[\]\]\$postCutoffEvents\s*=\s*\[object\[\]\]@\(\)[\s\S]*\[object\[\]\]\$PostCutoffState\.events\.ToArray\(\)'),
      @('scoped_baseline_native_fence_poison_schema', $baselineFunction,
        "'snf'[\s\S]*'snbusy'[\s\S]*'sncf'[\s\S]*'sncb'[\s\S]*'snff'[\s\S]*'sncsf'[\s\S]*'sncsb'[\s\S]*'sncof'[\s\S]*'sncob'[\s\S]*'snfsf'[\s\S]*'snfof'[\s\S]*'snffm'[\s\S]*'snflm'[\s\S]*'snfmg'[\s\S]*'snftr'[\s\S]*'sncerr'[\s\S]*'snul'[\s\S]*'snuid'[\s\S]*'snq'[\s\S]*'snseq'[\s\S]*'pnat'[\s\S]*'ppois'[\s\S]*'pnq'[\s\S]*'ppre'"),
      @('scoped_post_native_stream_and_health', $postFunction,
        "(?s)\A(?=.*'u21'\s+1)(?=.*'upcon'\s+1)(?=.*'pnat'\s+1)(?=.*ground_proxy_native_poison_zero[\s\S]*?'ppois'\s+0)(?=.*ground_proxy_native_quarantine_is_precommit_only[\s\S]*?'pnq==ppre')(?=.*ground_matching_USB_param_values_932)(?=.*vehicle_native_fence_committed_once)(?=.*vehicle_native_cancel_frame_partition_exact)(?=.*vehicle_native_cancel_byte_partition_exact)(?=.*vehicle_native_stat_runtime_cancel_bytes_exact)(?=.*vehicle_native_filter_frame_partition_exact)(?=.*vehicle_native_unexpected_id_hex32_zero)(?=.*vehicle_d7_param_value_full_partition_exact)(?=.*vehicle_target_frames_queued_exact)(?=.*vehicle_target_chunks_exact)(?=.*vehicle_native_frames_queued_exact)(?=.*vehicle_native_sequence_failures_zero)(?=.*psfail)(?=.*prej)"),
      @('scoped_parser_clean_all_fields', $integrityFunction,
        'Unsupported\s+-eq\s+0[\s\S]*UnsupportedFlags\s+-eq\s+0[\s\S]*BadPayloadLength\s+-eq\s+0[\s\S]*BadCrc\s+-eq\s+0[\s\S]*NoiseBytes\s+-eq\s+0[\s\S]*Buffer\.Count\s+-eq\s+0'),
      @('scoped_identity_exact_status_problem', $identityFunction,
        "AllowEmptyCollection[\s\S]*OrdinalIgnoreCase[\s\S]*'OK'[\s\S]*problem_code[\s\S]*no_duplicate_or_role_swapped_identity"),
      @('scoped_wait_reappear_empty_poll_model', $pollSequenceFunction,
        "Test-RoleIdentityBinding[\s\S]*empty_poll_count[\s\S]*ports_reappeared[\s\S]*ports_opened[\s\S]*timed_out"),
      @('scoped_wait_reappear_stability_selftests', $selfTestFunction,
        'wait_reappear_first_valid_poll_does_not_bind[\s\S]*wait_reappear_invalid_poll_resets_stability_window[\s\S]*wait_reappear_continuous_exact_5000ms_enables_open'),
      @('scoped_reader_broker_open_start_ioexception_selftest',
        $selfTestFunction,
        'reader_broker_open_start_ioexception_surfaces_exact_error'),
      @('scoped_live_wait_linked_to_binding_valid', $liveBoundWaitFunction,
        'Get-LivePortInventory[\s\S]*Test-RoleIdentityBinding[\s\S]*if\s*\(\$lastBinding\.valid\)[\s\S]*found=\$true[\s\S]*found=\$false'),
      @('scoped_pre_power_decision_fail1_no_actions',
        $prePowerDecisionFunction,
        'status=''FAIL''[\s\S]*exit_code=1[\s\S]*wait_started=\$false[\s\S]*vehicle=0;ground=0[\s\S]*request_write_count=0'),
      @('scoped_progress_or_predicate', $progressFunction,
        'timeDue[\s\S]*indexDue[\s\S]*-not \$timeDue\s+-and\s+-not \$indexDue[\s\S]*PROGRESS indexed='),
      @('scoped_all_evidence_streams_closed_before_raw_hash',
        $streamSealFunction,
        'VehicleRawStream\.Flush\(\$true\)[\s\S]*GroundRawStream\.Flush\(\$true\)[\s\S]*LiveProgressStream\.Flush\(\$true\)[\s\S]*VehicleRawStream\.Dispose\(\)[\s\S]*GroundRawStream\.Dispose\(\)[\s\S]*LiveProgressStream\.Dispose\(\)[\s\S]*Get-FileHash[\s\S]*Get-FileHash'),
      @('scoped_raw_length_and_hash_validation',
        $streamSealFunction,
        'vehicleFile\.Length\s+-ne\s+\$ExpectedVehicleBytes[\s\S]*groundFile\.Length\s+-ne\s+\$ExpectedGroundBytes[\s\S]*Get-FileHash[\s\S]*-ErrorAction\s+Stop[\s\S]*vehicleSha256[\s\S]*\^\[0-9A-F\]\{64\}\$'),
      @('scoped_selftest_vehicle_scheduler_field_cases', $selfTestFunction,
        "foreach\s*\(\s*\`$queueKey\s+in\s+@\('pgq','pga','prq','ptq'\)\)[\s\S]*baseline_vehicle_[\s\S]*_nonzero_rejected[\s\S]*Test-BaselineSetup"),
      @('scoped_selftest_real_cases', $selfTestFunction,
        "identity_role_swap_rejected[\s\S]*identity_empty_inventory_valid_false_no_error[\s\S]*identity_null_inventory_rejected[\s\S]*wait_reappear_empty_then_exact[\s\S]*wait_reappear_wrong_inventory_timeout[\s\S]*wait_reappear_malformed_inventory_timeout[\s\S]*wait_reappear_ports_open_progression[\s\S]*pre_power_empty_measured_fail_suppressed[\s\S]*readiness_no_heartbeat_clean_rejected[\s\S]*readiness_hb_only_rejected[\s\S]*readiness_d7_only_rejected[\s\S]*readiness_wrong_source_rejected[\s\S]*readiness_one_heartbeat_tail_rejected[\s\S]*readiness_stale_hb_outside_window_rejected[\s\S]*readiness_parser_error_rejected[\s\S]*readiness_parser_noise_partial_rejected[\s\S]*readiness_boot_change_rejected[\s\S]*readiness_q_stale_rejected[\s\S]*readiness_counter_decrease_rejected[\s\S]*readiness_delayed_valid[\s\S]*readiness_A_hang_deadline_rejected[\s\S]*readiness_B_hang_deadline_clamped[\s\S]*readiness_absolute_deadline_no_second_rounding[\s\S]*readiness_B_write_timeout_clamped[\s\S]*readiness_absolute_deadline_flush_eliminated[\s\S]*readiness_write_margin_boundary_rejected[\s\S]*readiness_A_timeout_skips_window_B[\s\S]*readiness_A_delayed_B_stale_rejected[\s\S]*readiness_last_snapshot_only_valid_bracket[\s\S]*readiness_device_ms_brackets_5s[\s\S]*readiness_timeout_deadline_from_ports_opened[\s\S]*readiness_timeout_boundary_no_short_window[\s\S]*readiness_timeout_setup_invalid_fail1[\s\S]*m0_reject_disables_resets_parser[\s\S]*baseline_vehicle_d7f_zero_rejected[\s\S]*baseline_ground_rfv_zero_rejected[\s\S]*baseline_ground_usbacc_zero_rejected[\s\S]*baseline_stale_generic_reconciliation_rejected[\s\S]*baseline_normal_rb1_ew3_allowed[\s\S]*baseline_normal_obf2_obb42_allowed[\s\S]*baseline_cumulative_discard_nonzero_allowed[\s\S]*baseline_ground_backlog_nonempty_rejected[\s\S]*baseline_related_drop_error_rejected[\s\S]*backlog_drain_current_mismatch_retries[\s\S]*backlog_drain_delayed_stable_pass[\s\S]*backlog_partial_snapshot_retryable_with_shared_deadline[\s\S]*backlog_partial_snapshot_resync_same_boot_monotonic[\s\S]*backlog_partial_snapshot_recovery_resets_stable_pair[\s\S]*backlog_partial_snapshot_overflow_not_retryable[\s\S]*backlog_partial_snapshot_retry_exhausted_write0[\s\S]*backlog_partial_snapshot_shared_deadline_no_extension[\s\S]*backlog_initial_ground_recovery_null_previous_safe[\s\S]*backlog_initial_ground_recovery_null_expected_q_reachable[\s\S]*backlog_unanchored_recovery_guard_fail_closed[\s\S]*backlog_recovery_reject_preserves_pre_reset_matcher[\s\S]*backlog_drain_cumulative_discard_stable_pass[\s\S]*backlog_drain_cumulative_discard_increment_rejected[\s\S]*backlog_drain_to_baseline_cumulative_discard_stable_pass[\s\S]*backlog_drain_to_baseline_cumulative_discard_increment_rejected[\s\S]*backlog_drain_to_baseline_cumulative_discard_missing_rejected[\s\S]*backlog_drain_two_observations_5s[\s\S]*backlog_drain_timeout_write0[\s\S]*pre_request_vehicle_clean_pass[\s\S]*pre_request_vehicle_boot_change_rejected[\s\S]*pre_request_vehicle_d722_increase_rejected[\s\S]*pre_request_vehicle_reconciliation_rejected[\s\S]*pre_request_vehicle_queue_nonzero_rejected[\s\S]*pre_request_exact_stat_runtime_retryable[\s\S]*pre_request_unknown_or_indexed_not_retryable[\s\S]*pre_request_stat_runtime_plus_parser_or_hb_failure_not_retryable[\s\S]*pre_request_stat_runtime_retry_then_clean_pass[\s\S]*pre_request_stat_runtime_retry_exhausted_write0[\s\S]*pre_request_retry_shared_deadline_no_extension[\s\S]*pre_request_stat_runtime_retry_fixture0_until_clean[\s\S]*pre_request_retry_stable_backlog_pair_promoted[\s\S]*pre_request_retry_stale_or_nonfinal_pair_rejected_write0[\s\S]*pre_request_retry_promoted_pair_d722_rf22_mismatch_rejected_write0[\s\S]*pre_request_retry_invalid_gate_or_continuity_rejected_write0[\s\S]*pre_request_periodic_stat_runtime_promoted_pair_then_clean_m0_pass[\s\S]*pre_request_direct_snapshot_invalid_sync_latched[\s\S]*post_vehicle_anchor_advances_through_retry_recovery_snapshots[\s\S]*post_vehicle_anchor_uses_latest_complete_pre_request[\s\S]*post_request_suppressed_assessment_not_run[\s\S]*post_request_suppressed_complete_snapshots_are_diagnostic_only[\s\S]*post_acknowledged_exactly_once_enables_success_contract[\s\S]*post_uncertain_or_nonack_success_contract_not_run[\s\S]*baseline_post_diagnostics[\s\S]*post_acknowledged_once_missing_u21_still_rejected[\s\S]*post_native_stream_rf22_not_exact_rejected[\s\S]*semantic_unknown_sentinel_continues_to_complete[\s\S]*semantic_extra_frame_continues_through_guard[\s\S]*semantic_anomaly_does_not_reset_stall[\s\S]*first_anomaly_metadata_frozen[\s\S]*param_event_cap_truncation_error[\s\S]*pre_request_backlog_clean_pass[\s\S]*pre_request_backlog_readiness_audited_not_blocking[\s\S]*pre_request_backlog_m0_not_completed_rejected[\s\S]*pre_request_backlog_m0_rejected[\s\S]*pre_request_backlog_known_sentinel_audited_not_blocking[\s\S]*official_post_cutoff_separated[\s\S]*post_cutoff_does_not_mutate_official[\s\S]*param_list_diagnostic_schema[\s\S]*diagnostic_stop_reason_proxy_terminal[\s\S]*parser_unsupported_id[\s\S]*positive_932_mavlink_sequence_wraps[\s\S]*long_counter_boundaries[\s\S]*live_progress_durable_order[\s\S]*durable_json_empty_array_exact[\s\S]*durable_json_array_cardinality_preserved[\s\S]*durable_json_nonarray_bytes_unchanged[\s\S]*readiness_raw_fsync_r4_phase_split[\s\S]*readiness_idle_fsync_clock_propagates[\s\S]*preopen_power_off_timeout_finalize"))) {
    [string]$scopedName = [string]($scoped[0])
    [string]$scopedText = [string]($scoped[1])
    [string]$scopedPattern = [string]($scoped[2])
    [bool]$scopedPassed = ($scopedText -match $scopedPattern)
      if ($scopedName -ceq 'scoped_selftest_real_cases') {
        [string[]]$newSelfCaseNames = @(
        'post_native_r5_classified_stat_runtime_pass',
        'post_native_classification_missing_field_rejected',
        'post_native_classification_partition_mutations_rejected',
        'post_native_cancelled_frame_bytes_mutations_rejected',
        'post_native_unexpected_latch_mutations_rejected',
        'post_native_snuid_format_mutations_rejected',
        'post_native_d722_partition_mutation_rejected',
        'post_native_target_lane_mutations_rejected',
        'post_native_filter_timing_mutations_rejected',
        'post_native_preexisting_abnormal_zero_delta_rejected',
        'pre_request_exact_stat_runtime_active_frame_retryable',
        'pre_request_exact_stat_runtime_active_pga_gt_one_not_retryable',
        'pre_request_exact_stat_runtime_active_queue_shape_not_retryable',
        'pre_request_exact_stat_runtime_active_event_shape_not_retryable',
        'pre_request_exact_stat_runtime_active_other_queue_or_error_not_retryable',
        'pre_request_exact_stat_runtime_active_attempt_or_deadline_bounded_write0',
        'pre_request_exact_stat_runtime_active_retry_then_stable_pair_reacquisition',
        'pre_request_silent_stat_runtime_queued_pgq1_pga0_retryable',
        'pre_request_silent_stat_runtime_queued_exact_failure_set_and_baseline_d7pb_drained',
        'pre_request_silent_stat_runtime_queued_unknown_indexed_crc_partial_not_retryable',
        'pre_request_silent_stat_runtime_queued_other_queue_or_error_not_retryable',
        'pre_request_silent_stat_runtime_queued_attempt_or_deadline_bounded_write0',
        'pre_request_silent_stat_runtime_queued_retry_then_stable_pair_reacquisition',
        'pre_request_vehicle_d7pb_nonzero_rejected',
        'pre_request_exact_stat_runtime_active_d7pb_nonzero_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_bounds_1_279_retry_only_write0',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_280_not_retryable',
        'pre_request_silent_stat_runtime_inflight_official_d7pb_nonzero_not_retryable',
        'pre_request_r7_stat_runtime_two_heartbeat_gap_prior_partial_retry_only_write0',
        'pre_request_r7_gap_nonheartbeat_noncontiguous_or_payload_mismatch_not_retryable',
        'pre_request_r7_gap_crc_false_not_retryable',
        'pre_request_r7_gap_null_event_rejected_without_throw',
        'pre_request_r7_gap_missing_wire_or_partial_bound_not_retryable',
        'pre_request_r7_gap_any_crc_error_not_retryable',
        'pre_request_r7_gap_attempt_deadline_bounded_write0',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_capture_incomplete_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_missing_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_multiple_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_crc_invalid_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_parser_integrity_not_clean_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_raw_range_invalid_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_sequence_mismatch_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_tuple_mismatch_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_source_mismatch_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_boundary_mismatch_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_m0_event_nonzero_not_retryable',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_attempt_or_deadline_bounded_write0',
        'pre_request_silent_stat_runtime_inflight_partial_d7pb_retry_then_clean_d7pb0_accept',
        'pre_request_observed_stat_runtime_partial_d7_shadow_retryable',
        'pre_request_observed_stat_runtime_partial_d7_exact_failure_and_correlation',
        'pre_request_observed_stat_runtime_partial_d7_event_shape_not_retryable',
        'pre_request_observed_stat_runtime_partial_d7_unknown_indexed_multiple_not_retryable',
        'pre_request_observed_stat_runtime_partial_d7_causal_shape_not_retryable',
        'pre_request_observed_stat_runtime_partial_d7_observer_delta_not_retryable',
        'pre_request_observed_stat_runtime_partial_d7_bounds_and_official_empty',
        'pre_request_observed_stat_runtime_partial_d7_queue_or_error_not_retryable',
        'pre_request_observed_stat_runtime_partial_d7_attempt3_or_deadline_write0',
        'pre_request_observed_stat_runtime_partial_d7_retry_then_attempt3_clean_accept',
        'pre_request_isolated_partial_d7_attempt3_arms_extra_write0',
        'pre_request_isolated_partial_d7_bounds_and_fail_closed',
        'pre_request_isolated_partial_d7_dedicated_budget_single_use_write0',
        'pre_request_isolated_partial_d7_attempt4_clean_accept_write0',
        'pre_request_isolated_partial_d7_attempt4_nonclean_rejected_write0',
        'pre_request_exact_wire_stat_runtime_attempt3_arms_extra_write0',
        'pre_request_exact_wire_stat_runtime_extra_near_miss_silent_faults_rejected',
        'pre_request_exact_wire_stat_runtime_attempt4_clean_accept_write0',
        'pre_request_exact_wire_stat_runtime_attempt4_recurrence_rejected_write0',
        'pre_request_dedicated_extra_token_mutually_exclusive_total4',
        'wait_reappear_first_valid_poll_does_not_bind',
        'wait_reappear_invalid_poll_resets_stability_window',
        'wait_reappear_continuous_exact_5000ms_enables_open',
        'reader_broker_open_start_ioexception_surfaces_exact_error',
        'pre_request_retry_stable_backlog_pair_promoted',
        'pre_request_retry_stale_or_nonfinal_pair_rejected_write0',
        'pre_request_retry_promoted_pair_d722_rf22_mismatch_rejected_write0',
        'pre_request_retry_invalid_gate_or_continuity_rejected_write0',
        'pre_request_periodic_stat_runtime_promoted_pair_then_clean_m0_pass',
        'post_acknowledged_exactly_once_enables_success_contract',
        'post_uncertain_or_nonack_success_contract_not_run',
        'readiness_raw_fsync_r4_phase_split',
        'readiness_idle_fsync_clock_propagates'
      )
      [string]$corePattern = $scopedPattern
      [bool]$newCasesDeclaredExactlyOnce = $true
      foreach ($newSelfCaseName in $newSelfCaseNames) {
        $corePattern = $corePattern.Replace(
            ($newSelfCaseName + '[\s\S]*'), '')
        [string]$declarationPattern = "Add-SelfCase\s+'" +
            [regex]::Escape($newSelfCaseName) + "'"
        if ([regex]::Matches(
            $scopedText, $declarationPattern).Count -ne 1) {
          $newCasesDeclaredExactlyOnce = $false
        }
      }
      [bool]$promotionCasesOrdered = ($scopedText -match
        'pre_request_retry_stable_backlog_pair_promoted[\s\S]*pre_request_retry_stale_or_nonfinal_pair_rejected_write0[\s\S]*pre_request_retry_promoted_pair_d722_rf22_mismatch_rejected_write0[\s\S]*pre_request_retry_invalid_gate_or_continuity_rejected_write0[\s\S]*pre_request_periodic_stat_runtime_promoted_pair_then_clean_m0_pass')
      [bool]$activeRaceCasesOrdered = ($scopedText -match
        'pre_request_exact_stat_runtime_active_frame_retryable[\s\S]*pre_request_exact_stat_runtime_active_pga_gt_one_not_retryable[\s\S]*pre_request_exact_stat_runtime_active_queue_shape_not_retryable[\s\S]*pre_request_exact_stat_runtime_active_event_shape_not_retryable[\s\S]*pre_request_exact_stat_runtime_active_other_queue_or_error_not_retryable[\s\S]*pre_request_exact_stat_runtime_active_attempt_or_deadline_bounded_write0[\s\S]*pre_request_exact_stat_runtime_active_retry_then_stable_pair_reacquisition')
      [bool]$queuedRaceCasesOrdered = ($scopedText -match
        'pre_request_silent_stat_runtime_queued_pgq1_pga0_retryable[\s\S]*pre_request_silent_stat_runtime_queued_exact_failure_set_and_baseline_d7pb_drained[\s\S]*pre_request_silent_stat_runtime_queued_unknown_indexed_crc_partial_not_retryable[\s\S]*pre_request_silent_stat_runtime_queued_other_queue_or_error_not_retryable[\s\S]*pre_request_silent_stat_runtime_queued_attempt_or_deadline_bounded_write0[\s\S]*pre_request_silent_stat_runtime_queued_retry_then_stable_pair_reacquisition')
      [bool]$d7pbCasesOrdered = ($scopedText -match
        'pre_request_vehicle_d7pb_nonzero_rejected[\s\S]*pre_request_exact_stat_runtime_active_d7pb_nonzero_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_bounds_1_279_retry_only_write0[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_280_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_official_d7pb_nonzero_not_retryable[\s\S]*pre_request_r7_stat_runtime_two_heartbeat_gap_prior_partial_retry_only_write0[\s\S]*pre_request_r7_gap_nonheartbeat_noncontiguous_or_payload_mismatch_not_retryable[\s\S]*pre_request_r7_gap_crc_false_not_retryable[\s\S]*pre_request_r7_gap_null_event_rejected_without_throw[\s\S]*pre_request_r7_gap_missing_wire_or_partial_bound_not_retryable[\s\S]*pre_request_r7_gap_any_crc_error_not_retryable[\s\S]*pre_request_r7_gap_attempt_deadline_bounded_write0[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_capture_incomplete_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_missing_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_multiple_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_crc_invalid_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_parser_integrity_not_clean_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_raw_range_invalid_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_sequence_mismatch_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_tuple_mismatch_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_source_mismatch_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_boundary_mismatch_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_m0_event_nonzero_not_retryable[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_attempt_or_deadline_bounded_write0[\s\S]*pre_request_silent_stat_runtime_inflight_partial_d7pb_retry_then_clean_d7pb0_accept')
      [bool]$observedPartialCasesOrdered = ($scopedText -match
        'pre_request_observed_stat_runtime_partial_d7_shadow_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_exact_failure_and_correlation[\s\S]*pre_request_observed_stat_runtime_partial_d7_event_shape_not_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_unknown_indexed_multiple_not_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_causal_shape_not_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_observer_delta_not_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_bounds_and_official_empty[\s\S]*pre_request_observed_stat_runtime_partial_d7_queue_or_error_not_retryable[\s\S]*pre_request_observed_stat_runtime_partial_d7_attempt3_or_deadline_write0[\s\S]*pre_request_observed_stat_runtime_partial_d7_retry_then_attempt3_clean_accept')
      [bool]$isolatedD7CasesOrdered = ($scopedText -match
        'pre_request_isolated_partial_d7_attempt3_arms_extra_write0[\s\S]*pre_request_isolated_partial_d7_bounds_and_fail_closed[\s\S]*pre_request_isolated_partial_d7_dedicated_budget_single_use_write0[\s\S]*pre_request_isolated_partial_d7_attempt4_clean_accept_write0[\s\S]*pre_request_isolated_partial_d7_attempt4_nonclean_rejected_write0')
      [bool]$wireExtraCasesOrdered = ($scopedText -match
        'pre_request_exact_wire_stat_runtime_attempt3_arms_extra_write0[\s\S]*pre_request_exact_wire_stat_runtime_extra_near_miss_silent_faults_rejected[\s\S]*pre_request_exact_wire_stat_runtime_attempt4_clean_accept_write0[\s\S]*pre_request_exact_wire_stat_runtime_attempt4_recurrence_rejected_write0[\s\S]*pre_request_dedicated_extra_token_mutually_exclusive_total4')
      [bool]$postCasesOrdered = ($scopedText -match
        'post_request_suppressed_assessment_not_run[\s\S]*post_request_suppressed_complete_snapshots_are_diagnostic_only[\s\S]*post_acknowledged_exactly_once_enables_success_contract[\s\S]*post_uncertain_or_nonack_success_contract_not_run[\s\S]*baseline_post_diagnostics[\s\S]*post_acknowledged_once_missing_u21_still_rejected')
      $scopedPassed = ($scopedText -match $corePattern) -and
          $newCasesDeclaredExactlyOnce -and $activeRaceCasesOrdered -and
          $queuedRaceCasesOrdered -and $d7pbCasesOrdered -and
          $observedPartialCasesOrdered -and $isolatedD7CasesOrdered -and
          $wireExtraCasesOrdered -and
          $promotionCasesOrdered -and
          $postCasesOrdered
    }
    Add-Check -Name $scopedName -Passed $scopedPassed `
        -Detail 'AST-scoped semantic contract (dummy literals elsewhere do not satisfy).'
  }
  Add-Check -Name 'vehicle_partial_usb_wake_constants_exact' `
      -Passed ($source -match
        '\$script:VehiclePartialUsbWakeStallMs\s*=\s*\[double\]250\.0' -and
        $source -match
        '\$script:VehiclePartialUsbWakeMinimumRemainingMs\s*=\s*\[double\]600\.0' -and
        $source -match
        '\$script:VehiclePartialUsbWakeWriteTimeoutMs\s*=\s*\[double\]100\.0' -and
        $source -match
        '\$script:VehiclePartialUsbWakeMaxAttempts\s*=\s*\[int\]1' -and
        $source -match
        '\$script:VehiclePartialUsbWakeByte\s*=\s*\[byte\[\]\]@\(\[byte\]0x0D\)') `
      -Detail 'Vehicle B recovery is frozen to one CR, one attempt, 250 ms stall, and 600 ms remaining.'
  Add-Check -Name 'vehicle_partial_usb_wake_predicate_fail_closed' `
      -Passed ($vehiclePartialUsbWakeFunction -match
        'AllowVehiclePartialUsbWake[\s\S]*Role[\s\S]*ExpectedQ[\s\S]*QueryCount[\s\S]*QueryAttemptCount[\s\S]*WriteTimedOut[\s\S]*ReportComplete' -and
        $vehiclePartialUsbWakeFunction -match
        'PreQueryMatcherSnapshot[\s\S]*CurrentMatcherSnapshot[\s\S]*StartLineIndex[\s\S]*StartRawOffset' -and
        $vehiclePartialUsbWakeFunction -match
        'pending_byte_count[\s\S]*pending_bytes_hex[\s\S]*pending_start_offset[\s\S]*overflow_count[\s\S]*tagged_line_count[\s\S]*raw_bytes' -and
        $vehiclePartialUsbWakeFunction -match
        'VCSTAT1 q=[\s\S]*v=6 boot=[\s\S]*gr=[\s\S]*prefixExact' -and
        $vehiclePartialUsbWakeFunction.Contains(
          'VehiclePartialUsbWakeStallMs') -and
        $vehiclePartialUsbWakeFunction.Contains(
          'VehiclePartialUsbWakeMinimumRemainingMs') -and
        $vehiclePartialUsbWakeFunction -match
          'Get-DeadlineBoundWritePlan[\s\S]*ConfiguredWriteTimeoutMs\s+\$script:VehiclePartialUsbWakeWriteTimeoutMs[\s\S]*MarginMs\s+\$script:SnapshotWriteDeadlineMarginMs' -and
        $vehiclePartialUsbWakeFunction -match
        'eligible[\s\S]*not_opted_in[\s\S]*wrong_role[\s\S]*missing_expected_q[\s\S]*query_not_exact[\s\S]*attempt_exhausted[\s\S]*pre_query_matcher_dirty[\s\S]*matcher_overflow_changed[\s\S]*tagged_line_progress[\s\S]*pending_not_printable[\s\S]*raw_not_contiguous[\s\S]*prefix_not_exact[\s\S]*stall_below_threshold[\s\S]*insufficient_deadline') `
      -Detail 'Wake requires the exact expected-q contiguous printable R3 prefix and every clean matcher/deadline gate.'
  [int]$usbWakeBranchStart = $snapshotQueryFunction.IndexOf(
      'if ($AllowVehiclePartialUsbWake -and -not $report.complete)',
      [StringComparison]::Ordinal)
  [int]$usbWakeBranchEnd = if ($usbWakeBranchStart -ge 0) {
    $snapshotQueryFunction.IndexOf(
      'if ($read -eq 0 -and -not $report.complete)',
      $usbWakeBranchStart, [StringComparison]::Ordinal)
  } else { -1 }
  [string]$usbWakeBranch = if ($usbWakeBranchStart -ge 0 -and
      $usbWakeBranchEnd -gt $usbWakeBranchStart) {
    $snapshotQueryFunction.Substring($usbWakeBranchStart,
      $usbWakeBranchEnd - $usbWakeBranchStart)
  } else { '' }
  Add-Check -Name 'snapshot_query_usb_wake_one_byte_bounded_no_flush' `
      -Passed ($usbWakeBranch.Contains('Get-VehiclePartialUsbWakeDecision') -and
        $usbWakeBranch -match
          'Serial\.Write\(\$script:VehiclePartialUsbWakeByte,\s*0,[\s\S]{0,100}\$script:VehiclePartialUsbWakeByte\.Length\)' -and
        $usbWakeBranch.Contains('++$usbWakeAttemptCount') -and
        $usbWakeBranch.Contains('++$usbWakeWriteCount') -and
        $usbWakeBranch.Contains('write_timeout_ms') -and
        -not $usbWakeBranch.Contains('BaseStream.Flush') -and
        -not $usbWakeBranch.Contains('DiagnosticQueryWriteCount') -and
        -not ($usbWakeBranch -match
          '\$effectiveDeadlineElapsedMs\s*=') -and
        $snapshotQueryFunction -match
          'usb_wake_attempt_count\s*=\s*\$usbWakeAttemptCount[\s\S]*usb_wake_write_count\s*=\s*\$usbWakeWriteCount[\s\S]*usb_wake_trigger_decision[\s\S]*usb_wake_deadline_extended\s*=\s*\$false[\s\S]*usb_wake_base_stream_flush_performed\s*=\s*\$false') `
      -Detail 'Eligible recovery writes only one deadline-bound CR, never flushes or increments the diagnostic-query counter, and exposes separate evidence.'
  $snapshotQueryCommandAsts = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
          $node.GetCommandName() -ceq 'Invoke-SnapshotQuery'
    }, $true))
  $usbWakeOptInCommandAsts = @($snapshotQueryCommandAsts | Where-Object {
      @($_.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -ceq 'AllowVehiclePartialUsbWake'
      }).Count -eq 1
    })
  Add-Check -Name 'readiness_vehicle_B_only_usb_wake_opt_in' `
      -Passed ($usbWakeOptInCommandAsts.Count -eq 1 -and
        $usbWakeOptInCommandAsts[0].Extent.Text.Contains(
          "readiness_vehicle_B_") -and
        $usbWakeOptInCommandAsts[0].Extent.Text.Contains(
          '-ExpectedQ $expectedB') -and
        -not $usbWakeOptInCommandAsts[0].Extent.Text.Contains(
          "readiness_vehicle_A_")) `
      -Detail ('opt_in_invocation_count=' + $usbWakeOptInCommandAsts.Count)
  Add-Check -Name 'vehicle_partial_usb_wake_selftest_live_shared' `
      -Passed ($selfTestFunction.Contains(
          'Get-VehiclePartialUsbWakeDecision') -and
        $selfTestFunction.Contains(
          'readiness_vehicle_B_usb_wake_model.json') -and
        $snapshotQueryFunction.Contains(
          'Get-VehiclePartialUsbWakeDecision')) `
      -Detail 'The pure decision helper is exercised offline and used by the live snapshot query.'
  Add-Check -Name 'backlog_resync_only_for_partial_clean_matcher_without_overflow' `
      -Passed ($backlogRecoveryDispositionFunction -match
        'Response\.valid[\s\S]*ACCEPT' -and
        $backlogRecoveryDispositionFunction -match
        '(?:MatcherAfter|matcher_after)[\s\S]*overflow[\s\S]*(?:MatcherBefore|matcher_before)[\s\S]*overflow' -and
        $backlogRecoveryDispositionFunction -match
        '(?:RetryBudgetAvailable|retryBudgetAvailable)[\s\S]*(?:AttemptNumber|attemptNumber)[\s\S]*(?:MaxAttempts|maxAttempts)[\s\S]*RESYNC' -and
        $backlogRecoveryDispositionFunction -match
        '(?:overflow|retry_exhausted|deadline)[\s\S]*REJECT') `
      -Detail 'Only a bounded timeout/partial with unchanged matcher-overflow state may resynchronize; overflow, exhausted budget, and deadline remain fail-closed.'
  Add-Check -Name 'backlog_resync_reestablishes_q_but_proves_same_epoch_monotonicity' `
      -Passed ($backlogSnapshotRecoveryFunction -match
        'ExpectedQ\s+\$null' -and
        $backlogSnapshotRecoveryFunction.Contains(
          'Test-BacklogRecoveredSnapshotContinuity') -and
        $backlogRecoveryContinuityFunction -match
        'same_boot[\s\S]*(?:ms_increased|ms_monotonic)[\s\S]*(?:q_advanced|q_within)[\s\S]*(?:counter_monotonic|d722_monotonic|rf22_monotonic)[\s\S]*valid') `
      -Detail 'A retry may re-establish a lost q only after same-boot, increasing-ms, bounded-q, and role-counter monotonic checks.'
  [int]$nullPreviousBranchOffset =
      $backlogRecoveryContinuityFunction.IndexOf(
        'if ($null -eq $PreviousSnapshot)',
        [StringComparison]::Ordinal)
  [int]$firstPreviousQDereferenceOffset =
      $backlogRecoveryContinuityFunction.IndexOf(
        '$PreviousSnapshot.q_uint32',
        [StringComparison]::Ordinal)
  [int]$firstPreviousStatusDereferenceOffset =
      $backlogRecoveryContinuityFunction.IndexOf(
        '$PreviousSnapshot.status',
        [StringComparison]::Ordinal)
  [int]$firstPreviousDereferenceOffset = @(
      $firstPreviousQDereferenceOffset,
      $firstPreviousStatusDereferenceOffset) |
      Where-Object {$_ -ge 0} | Measure-Object -Minimum |
      Select-Object -ExpandProperty Minimum
  Add-Check -Name 'initial_ground_backlog_recovery_is_null_previous_safe' `
      -Passed ($nullPreviousBranchOffset -ge 0 -and
        ($null -eq $firstPreviousDereferenceOffset -or
         $nullPreviousBranchOffset -lt $firstPreviousDereferenceOffset) -and
        $backlogRecoveryContinuityFunction -match
          'anchor_confirmation_no_previous[\s\S]*AnchorSnapshot[\s\S]*RecoveredSnapshot[\s\S]*same_boot[\s\S]*ms[\s\S]*counter_monotonic[\s\S]*valid') `
      -Detail 'The first Ground recovery has no prior Ground snapshot; it must use a null-safe anchor-to-confirmation continuity proof before any PreviousSnapshot dereference.'
  Add-Check -Name 'initial_ground_recovery_null_expected_q_is_reachable_only_with_explicit_guard' `
      -Passed ($backlogRecoveryDispositionFunction -match
        'AllowUnanchoredGroundRecovery[\s\S]*Role[\s\S]*ExpectedQ' -and
        $backlogRecoveryDispositionFunction -match
        'Role\s+-ceq\s+''ground''[\s\S]*AllowUnanchoredGroundRecovery[\s\S]*\$null\s+-eq\s+\$ExpectedQ[\s\S]*pending_q_(?:present|parsed)[\s\S]*unanchored_ground_recovery' -and
        $backlogSnapshotRecoveryFunction -match
        'allowUnanchoredGroundRecovery\s*=\s*\(\$Role\s+-ceq\s+''ground''\s+-and\s+\$null\s+-eq\s+\$PreviousSnapshot\s+-and\s+\$null\s+-eq\s+\$ExpectedQ\)' -and
        $backlogSnapshotRecoveryFunction -match
        'Get-BacklogSnapshotRecoveryDisposition[\s\S]{0,900}-AllowUnanchoredGroundRecovery\s+\$allowUnanchoredGroundRecovery') `
      -Detail 'ExpectedQ=null may enter recovery only when the wrapper proves Role=ground and PreviousSnapshot=null and passes an explicit opt-in to the fail-closed disposition.'
  Add-Check -Name 'initial_ground_recovery_parses_partial_q_and_binds_both_followups' `
      -Passed ($backlogRecoveryDispositionFunction -match
        'qMatch[\s\S]*TryParse[\s\S]*pending_q_uint32' -and
        $backlogSnapshotRecoveryFunction -match
        'unanchored_ground_recovery[\s\S]*pending_q_uint32[\s\S]*Get-NextQueryId[\s\S]*anchorExpectedQ[\s\S]*Invoke-SnapshotQuery[\s\S]{0,800}-ExpectedQ\s+\$anchorExpectedQ' -and
        $backlogRecoveryContinuityFunction -match
        'FailedPartialQ[\s\S]*Get-NextQueryId[\s\S]*expectedAnchorQ[\s\S]*Get-NextQueryId[\s\S]*expectedRecoveredQ[\s\S]*Test-ReadinessSnapshotResponse[\s\S]*AnchorSnapshot[\s\S]*ExpectedQ\s+\$expectedAnchorQ[\s\S]*RecoveredSnapshot[\s\S]*ExpectedQ\s+\$expectedRecoveredQ' -and
        $backlogSnapshotRecoveryFunction -match
        'Test-BacklogRecoveredSnapshotContinuity[\s\S]{0,700}-FailedPartialQ\s+\$disposition\.pending_q_uint32') `
      -Detail 'The captured Ground partial q=N is parsed independently of ExpectedQ, then the wrapper and continuity proof require anchor=N+1 and confirmation=N+2.'
  [int]$settleRejectOffset = $backlogSnapshotRecoveryFunction.IndexOf(
      'if (-not $settleCapture.completed_duration',
      [StringComparison]::Ordinal)
  [int]$settleResetOffset = $backlogSnapshotRecoveryFunction.IndexOf(
      'Reset-TagMatcherCandidate -State $State',
      [StringComparison]::Ordinal)
  [bool]$rejectBeforeReset = ($settleRejectOffset -ge 0 -and
      $settleResetOffset -gt $settleRejectOffset)
  [bool]$explicitPreResetRetention = ($backlogDrainFunction -match
      'failed_recoveries[\s\S]*matcher_after_settle' -and
      $backlogDrainFunction -match
      'New-ReadinessSyncInvalidLatch[\s\S]{0,700}-MatcherSnapshot\s+\$\w+Recovery\.matcher_after_settle')
  Add-Check -Name 'backlog_recovery_reject_preserves_pre_reset_matcher' `
      -Passed (($rejectBeforeReset -or $explicitPreResetRetention) -and
        $backlogSnapshotRecoveryFunction -match
          'matcher_after_settle[\s\S]*pending_byte_count') `
      -Detail 'Deadline/overflow rejection must latch or durably retain the exact pending matcher before any candidate reset.'
  Add-Check -Name 'pre_request_retry_exact_stat_runtime_evidence_only' `
      -Passed ($preRequestDispositionFunction -match
        'known_STAT_RUNTIME_sentinel' -and
        $preRequestDispositionFunction -match
        'exact_silent_inflight_STAT_RUNTIME_race' -and
        $preRequestDispositionFunction -match
        'events\.Count\s*-eq\s*0' -and
        $preRequestDispositionFunction -match
        'm0_epoch_completed' -and
        $preRequestDispositionFunction -match
        'parser_integrity[\s\S]*valid' -and
        $preRequestDispositionFunction -match
        'heartbeat[\s\S]*valid[\s\S]*count' -and
        $preRequestDispositionFunction -match
        'anomaly_classes[\s\S]*(?:Count|count)[\s\S]*(?:-eq|eq)\s*0' -and
        $preRequestDispositionFunction -match
        '(?:unknown|indexed)[\s\S]*(?:-eq|eq)\s*0' -and
        $preRequestDispositionFunction -match
        'd722_stable[\s\S]*d722_rf22_reconciled[\s\S]*pgq' -and
        $preRequestDispositionFunction -match
        '(?:d722_delta|Get-SnapshotDelta)[\s\S]*(?:sentinel|known)' -and
        $preRequestDispositionFunction -match
        "STAT_RUNTIME[\s\S]*65535[\s\S]*932[\s\S]*6[\s\S]*RETRY") `
      -Detail 'RETRY is reserved for either an exact fresh observed STAT_RUNTIME sentinel race or an exact silent in-flight STAT_RUNTIME proof; both remain bounded, parser/HB-clean, anomaly-free, and write-zero.'
  Add-Check `
      -Name 'pre_request_partial_d7pb_retry_requires_exact_pre_m0_tail_proof' `
      -Passed ($preM0TailRaceDefinitions.Count -eq 1 -and
        $paramFunction -match 'crc_valid\s*=\s*\$true' -and
        $paramFunction -match 'param_value_hex' -and
        $preM0TailRaceFunction -match
          'exact_pre_M0_tail_STAT_RUNTIME_race' -and
        $preM0TailRaceFunction -match
          'completed_duration[\s\S]*requested_milliseconds[\s\S]*3000' -and
        $preM0TailRaceFunction -match
          'integrity[\s\S]*valid[\s\S]*events[\s\S]*Count\s*-eq\s*1' -and
        $preM0TailRaceFunction -match
          'crc_valid[\s\S]*message_id[\s\S]*22' -and
        $preM0TailRaceFunction -match
          'pvid[\s\S]*pvval[\s\S]*pvidx[\s\S]*pvcnt[\s\S]*pvtype[\s\S]*pvseq[\s\S]*pvsys[\s\S]*pvcomp' -and
        $preM0TailRaceFunction -match
          'raw_start_offset[\s\S]*raw_end_offset_exclusive[\s\S]*M0GroundRawOffset' -and
        $preM0TailRaceFunction -match 'M0Events[\s\S]*Count\s*-eq\s*0' -and
        $preRequestDispositionFunction -match
          'exactSilentPartialVehicleFailureSet[\s\S]*d7pb_empty' -and
        $preRequestDispositionFunction -match
          'exactPreM0TailStatRuntimeRace[\s\S]*preM0TailRaceEvidence\.valid' -and
        $officialPreRequestGateFunction -match
          'Get-PreRequestAttemptDisposition[\s\S]*-PreM0TailEvidence\s+\$preM0TailEvidence' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'Only d7pb 1..279 with one CRC-clean, tuple/source/value/sequence-correlated #22 ending exactly at the M0 Ground barrier in the completed 3 s raw tail, plus zero M0 events, may receive bounded write-zero RETRY.'
  Add-Check `
      -Name 'pre_request_r7_heartbeat_gap_retry_requires_full_wire_proof' `
      -Passed ($source -match
          'Complete-MavlinkCandidate[\s\S]*crc_valid\s*=\s*\$true' -and
        $paramFunction -match 'payload_hex\s*=\s*ConvertTo-Hex' -and
        $officialPreRequestGateFunction -match
          'ValidEvents\.ToArray\(\)[\s\S]*valid_events\s*=\s*\$preM0TailValidEvents' -and
        $preM0TailRaceFunction -match
          'valid_events[\s\S]*targetMirrorCount[\s\S]*-eq\s*1' -and
        $preM0TailRaceFunction -match
          'crcValidProperty[\s\S]*-is\s*\[bool\][\s\S]*payloadHexProperty' -and
        $preM0TailRaceFunction -match
          'frameVersionProperty[\s\S]*-eq\s*2[\s\S]*signedProperty' -and
        $preM0TailRaceFunction -match
          'leadingHeartbeatChainExact[\s\S]*expectedLeadingRawStart' -and
        $preM0TailRaceFunction -match
          'trailingHeartbeatChainExact[\s\S]*expectedTrailingRawStart' -and
        $preM0TailRaceFunction -match
          'fullTailWireChainExact[\s\S]*contiguous_vehicle_heartbeat_chain' -and
        $preM0TailRaceFunction -match
          'trailingHeartbeatCount\s*-ge\s*1[\s\S]*M0GroundRawOffset' -and
        $preRequestDispositionFunction -match
          'priorAndCurrentPartialD7pbBounded[\s\S]*\[uint64\]279' -and
        $preRequestDispositionFunction -match
          'exactPreM0TailHeartbeatGapPriorPartialD7Race[\s\S]*full_tail_wire_chain_exact[\s\S]*exactActiveErrorZero' -and
        $preRequestDispositionFunction -match
          'retryCandidate[\s\S]*exactPreM0TailHeartbeatGapPriorPartialD7Race' -and
        $preRequestDispositionFunction -match
          'exact_pre_M0_tail_STAT_RUNTIME_heartbeat_gap_prior_partial_D7_race' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'R7 prior/current partial-D7 state is RETRY-only when the sealed 3 s tail is fully covered by one exact STAT_RUNTIME and contiguous CRC-valid unsigned MAVLink2 Vehicle HEARTBEAT frames; null, CRC/type/payload/span/error faults stay write-zero REJECT.'
  Add-Check `
      -Name 'pre_request_observed_stat_runtime_partial_d7_requires_exact_m0_proof' `
      -Passed ($observedPartialRaceDefinitions.Count -eq 1 -and
        $observedPartialRaceFunction -match
          'crcValid[\s\S]*messageExact[\s\S]*payloadLengthExact' -and
        $observedPartialRaceFunction -match
          'valueExact[\s\S]*tupleExact[\s\S]*sourceExact[\s\S]*sequenceExact' -and
        $observedPartialRaceFunction -match
          'pre_request_m0[\s\S]*M0_pre_request_clean_5s' -and
        $observedPartialRaceFunction -match
          'rawStart\s*-ge\s*\$M0GroundRawOffset[\s\S]*rawEnd\s*-le\s*\$M0GateEndGroundRawOffset' -and
        $observedPartialRaceFunction -match
          'causalExact[\s\S]*targetCount[\s\S]*parserBufferEmpty[\s\S]*heartbeatCount[\s\S]*backlogSchemaExact' -and
        $preRequestDispositionFunction -match
          'exactObservedStatRuntimePartialD7Race[\s\S]*silentPartialD7pbBounded[\s\S]*observedPartialEventEvidence\.valid' -and
        $preRequestDispositionFunction -match
          'retryCandidate[\s\S]*exactObservedStatRuntimePartialD7Race' -and
        $officialPreRequestGateFunction -match
          'capture_start_barrier\.ground_raw_offset_exclusive' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'One complete CRC-clean M0 STAT_RUNTIME must correlate by wire value/tuple/source/sequence and broker-bounded raw range with the Vehicle observer; only d7pb 1..279 and exact clean counters/queues may receive bounded write-zero RETRY.'
  Add-Check `
      -Name 'pre_request_post_m0_vehicle_snapshot_partial_d7_requires_exact_same_snapshot_proof' `
      -Passed ($postM0SnapshotRaceDefinitions.Count -eq 1 -and
        $postM0SnapshotRaceFunction -match
          '(?s)(?=.*requested_milliseconds)(?=.*completed_duration)(?=.*deadline_reached)(?=.*\[int\]\$m0Requested\.value\s*-eq\s*5000)(?=.*\[bool\]\$m0Completed\.value)(?=.*-not\s+\[bool\]\$m0DeadlineReached\.value)' -and
        $postM0SnapshotRaceFunction -match
          'start_barrier[\s\S]*ground_raw_offset_exclusive[\s\S]*causalM0RawStart\.value\s*-eq\s*\[long\]\$m0StartRawOffset\.value' -and
        $postM0SnapshotRaceFunction -match
          'causalM0RawEnd\.value\s*-eq\s*\[long\]\$diagnosticRawStart\.value' -and
        $postM0SnapshotRaceFunction -match
          'events\.Count\s*-eq\s*1[\s\S]*crcValid[\s\S]*messageExact[\s\S]*payloadLengthExact' -and
        $postM0SnapshotRaceFunction -match
          'valueExact[\s\S]*tupleExact[\s\S]*sourceExact[\s\S]*sequenceExact[\s\S]*producerExact' -and
        $postM0SnapshotRaceFunction -match
          'producer_phase\.value\s*-ceq[\s\S]*snapshotName\.value[\s\S]*producer_epoch\.value\s*-ceq[\s\S]*snapshotName\.value' -and
        $postM0SnapshotRaceFunction -match
          'fresh_m0_only[\s\S]*readiness_events_audit_only[\s\S]*m0_veto_events' -and
        -not ($postM0SnapshotRaceFunction -match
          'stale_param_value_count|stale_generic_count') -and
        $preRequestDispositionFunction -match
          'exactPostM0SnapshotVehicleFailureSet[\s\S]*failedVehicleNames\.Count\s*-eq\s*4[\s\S]*d722_stable[\s\S]*d722_rf22_reconciled[\s\S]*pgq[\s\S]*d7pb_empty' -and
        $preRequestDispositionFunction -match
          'exactPostM0OfficialIdleReconciled[\s\S]*exactPostM0SnapshotSchedulerState[\s\S]*silentD722DeltaOne[\s\S]*silentPvokDeltaOne[\s\S]*exactActiveErrorZero[\s\S]*exactPostM0SnapshotEventEvidence\.valid' -and
        $preRequestDispositionFunction -match
          'AttemptNumber\s*-lt\s*\$MaxAttempts[\s\S]*RetryBudgetAvailable' -and
        -not $preRequestDispositionFunction.Contains('Invoke-SnapshotQuery') -and
        $officialPreRequestGateFunction -match
          '\$preRequestVehicle\s*=\s*Invoke-SnapshotQuery[\s\S]*Invoke-PumpPair(?:(?!Invoke-CaptureInterval|Start-Sleep|Wait-)[\s\S])*?\$postM0DiagnosticEndBarrier\s*=\s*Set-ReaderCaptureContext' -and
        $officialPreRequestGateFunction -match
          'Get-PreRequestAttemptDisposition[\s\S]*-M0Capture\s+\$m0Capture[\s\S]*-DiagnosticEndBarrier\s+\$postM0DiagnosticEndBarrier' -and
        $officialPreRequestGateFunction -match
          'Invoke-PreBaselineBacklogDrainGate[\s\S]*-AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs[\s\S]*Test-PreRequestRecoveryBacklogPairPromotion' -and
        $officialPreRequestGateFunction -match
          'deadline_extended\s*=\s*\$false[\s\S]*fixture_write_count\s*=\s*0' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_same_vehicle_snapshot_stat_runtime_retryable') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_snapshot_wire_observer_boundary_mismatch_rejected') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_snapshot_fresh_m0_partition_fault_rejected') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_snapshot_state_or_baseline_fault_rejected') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_snapshot_attempt_and_deadline_bounded_write0') -and
        $selfTestFunction.Contains(
          'pre_request_post_m0_snapshot_retry_uses_existing_stable_pair_path')) `
      -Detail 'Only one post-M0 STAT_RUNTIME wholly inside the same sealed Vehicle diagnostic, correlated to its observer and fresh M0 partition with exact idle/+1/partial-D7 state, may use the existing bounded same-deadline write-zero stable-pair RETRY.'
  Add-Check `
      -Name 'pre_request_isolated_d7pb_snapshot_race_exact_fail_closed' `
      -Passed ($isolatedD7RaceDefinitions.Count -eq 1 -and
        $obsoleteIsolatedD7DirectRecheckDefinitions.Count -eq 0 -and
        $isolatedD7RaceFunction -match
          'requiredVehicleCheckNames[\s\S]*response_exact[\s\S]*d7pb_empty[\s\S]*vehicleGateShapeExact' -and
        $isolatedD7RaceFunction -match
          'only_d7pb_empty_failed[\s\S]*causal_gate_valid[\s\S]*m0_epoch_completed[\s\S]*parser_integrity_valid[\s\S]*heartbeat_valid[\s\S]*m0_events_empty' -and
        $isolatedD7RaceFunction -match
          'snapshots_complete[\s\S]*official=0,current=1\.\.279' -and
        $isolatedD7RaceFunction -match
          'parameter_counters_stable_reconciled[\s\S]*d722=pvok=rf22' -and
        $isolatedD7RaceFunction -match
          'pvid[\s\S]*pvval[\s\S]*pvidx[\s\S]*pvcnt[\s\S]*pvtype[\s\S]*pvseq[\s\S]*pvsys[\s\S]*pvcomp[\s\S]*pvms' -and
        $isolatedD7RaceFunction -match
          'STAT_RUNTIME[\s\S]*65535[\s\S]*932[\s\S]*all_parameter_queues_empty[\s\S]*transport_and_parser_errors_zero' -and
        $isolatedD7RaceFunction -match
          'd7_stream_active_and_monotonic[\s\S]*fixture_write_count=0') `
      -Detail 'A sole d7pb 1..279 failure is classified only with a complete exact gate shape, clean causal M0/HB/parser evidence, stable known STAT_RUNTIME observer, empty queues/errors, reconciled counters, and active monotonic D7; the unused Vehicle-only recheck path is absent.'
  Add-Check `
      -Name 'pre_request_isolated_d7pb_disposition_attempt3_only' `
      -Passed ($preRequestDispositionFunction -match
          'IsolatedPartialD7ExtraRetryAvailable[\s\S]*Test-IsolatedPartialD7SnapshotRaceContract' -and
        $preRequestDispositionFunction -match
          'MaxAttempts\s*-eq\s*3[\s\S]*AttemptNumber\s*-eq\s*3' -and
        $preRequestDispositionFunction -match
          'RETRY_ISOLATED_D7PB[\s\S]*exact_isolated_partial_D7_snapshot_race' -and
        $preRequestDispositionFunction -match
          'isolated_partial_D7_extra_retry_exhausted[\s\S]*shared_deadline_exhausted' -and
        $preRequestDispositionFunction -match
          'isolated_partial_d7_extra_retry_selected[\s\S]*fixture_write_count=0' -and
        -not $preRequestDispositionFunction.Contains('Invoke-SnapshotQuery') -and
        -not $preRequestDispositionFunction.Contains('Write-ExactRequestOnce')) `
      -Detail 'The special action is RETRY-only on standard attempt 3 with one available token and the shared deadline; every exhausted path remains write-zero REJECT.'
  Add-Check `
      -Name 'pre_request_isolated_d7pb_gate_one_extra_full_bilateral_recovery' `
      -Passed ($officialPreRequestGateFunction -match
          '\[ValidateRange\(1,3\)\]\[int\]\$MaxAttempts\s*=\s*3' -and
        $officialPreRequestGateFunction -match
          'dedicatedExtraRetryLimit\s*=\s*1[\s\S]*totalAttemptLimit\s*=\s*\$MaxAttempts\s*\+\s*\$dedicatedExtraRetryLimit' -and
        $officialPreRequestGateFunction -match
          'while\s*\(\$attempt\s*-lt\s*\$totalAttemptLimit[\s\S]*isolatedPartialD7ExtraAttemptArmed' -and
        $officialPreRequestGateFunction -match
          'isolatedPartialD7ExtraAttemptArmed\s*=\s*\$false[\s\S]*\+\+\$attempt' -and
        $officialPreRequestGateFunction -match
          'IsolatedPartialD7ExtraRetryAvailable[\s\S]*RETRY_ISOLATED_D7PB' -and
        $officialPreRequestGateFunction -match
          'Invoke-PreBaselineBacklogDrainGate[\s\S]*-AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs[\s\S]*Test-PreRequestRecoveryBacklogPairPromotion[\s\S]*recoveryPairPromotion\.valid[\s\S]*isolatedPartialD7ExtraRetryUsed[\s\S]*isolatedPartialD7ExtraAttemptArmed\s*=\s*\$true' -and
        $officialPreRequestGateFunction -match
          'standard_max_attempts[\s\S]*total_attempt_limit[\s\S]*isolated_partial_d7_extra_retry_limit[\s\S]*isolated_partial_d7_extra_retry_used[\s\S]*dedicated_extra_attempt_executed' -and
        $officialPreRequestGateFunction -match
          'deadline_extended\s*=\s*\$false[\s\S]*fixture_write_count=0' -and
        -not ($officialPreRequestGateFunction -match
          '(?m)^\s*\$DeadlineElapsedMs\s*=') -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'The gate retains three general attempts, consumes at most one separate token only after full bilateral drain/promotion, executes at most attempt 4, never extends the absolute deadline, and never writes the request.'
  Add-Check `
      -Name 'pre_request_exact_wire_stat_runtime_shares_one_extra_slot_fail_closed' `
      -Passed ($officialPreRequestGateFunction -match
          'exactObservedStatRuntimeExtraRetryUsed\s*=\s*0[\s\S]*exactObservedStatRuntimeExtraAttemptArmed\s*=\s*\$false' -and
        $officialPreRequestGateFunction -match
          'totalAttemptLimit\s*=\s*\$MaxAttempts\s*\+\s*\$dedicatedExtraRetryLimit' -and
        $officialPreRequestGateFunction -match
          'isolatedPartialD7ExtraAttemptArmed[\s\S]*exactObservedStatRuntimeExtraAttemptArmed[\s\S]*throw\s+''dedicated extra retry arms must be mutually exclusive''' -and
        $officialPreRequestGateFunction -match
          'ExactObservedStatRuntimeExtraRetryAvailable[\s\S]*RETRY_EXACT_STAT_RUNTIME' -and
        $officialPreRequestGateFunction -match
          'Invoke-PreBaselineBacklogDrainGate[\s\S]*Test-PreRequestRecoveryBacklogPairPromotion[\s\S]*exactObservedStatRuntimeExtraRetryUsed[\s\S]*exactObservedStatRuntimeExtraAttemptArmed\s*=\s*\$true' -and
        $officialPreRequestGateFunction -match
          'dedicated_extra_attempt_kind[\s\S]*exact_observed_stat_runtime_extra_retry_limit[\s\S]*exact_observed_stat_runtime_extra_retry_used' -and
        $officialPreRequestGateFunction -match
          'deadline_extended\s*=\s*\$false[\s\S]*fixture_write_count=0' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'Only an exact wire-observed attempt-3 sentinel may share the single dedicated attempt-4 slot; it still requires full bilateral drain/promotion and a later clean M0, with no deadline extension or request write.'
  Add-Check -Name 'pre_request_retry_faults_are_nonretryable_and_write_zero' `
      -Passed ($preRequestDispositionFunction -match
        'REJECT' -and
        $preRequestDispositionFunction -match
        'fixture_write_count\s*=\s*0' -and
        $officialPreRequestGateFunction -match
        'if\s*\([^\)]*(?:REJECT|action)[\s\S]*?break' -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'Unknown/indexed/parser/HB/continuity faults and retry exhaustion stop before the sole fixture writer; the retry gate itself cannot write #21.'
  Add-Check -Name 'direct_pre_request_snapshot_invalid_latches_sync_invalid' `
      -Passed ($officialPreRequestGateFunction -match
        'if\s*\(-not\s+\$preResponse\.valid\)[\s\S]*New-ReadinessSyncInvalidLatch[\s\S]*vehicleSyncInvalid[\s\S]*syncInvalid\s*=\s*\$true[\s\S]*break' -and
        $officialPreRequestGateFunction -match
        'vehicle_sync_invalid\s*=\s*\$vehicleSyncInvalid' -and
        $syncInvalidMatcherFunction -match
        'PreRequestPairGate[\s\S]*PSObject\.Properties\[\$propertyName\][\s\S]*matcher_at_latch') `
      -Detail 'A direct pre-request diagnostic timeout/wrong-q/partial is synchronization-invalid, suppresses both post writes, and exposes its exact matcher latch.'
  Add-Check -Name 'pre_request_retry_promotes_only_verified_final_stable_backlog_pair' `
      -Passed ($preRequestRecoveryPromotionFunction -match
        'RecoveryBacklogGate[\s\S]*valid[\s\S]*sync_invalid[\s\S]*timed_out[\s\S]*fixture_write_count' -and
        $preRequestRecoveryPromotionFunction -match
        'observations[\s\S]*stable_pairs[\s\S]*Test-BacklogDrainStablePair[\s\S]*Test-BaselineSetup' -and
        $preRequestRecoveryPromotionFunction -match
        'last_vehicle_snapshot[\s\S]*last_ground_snapshot[\s\S]*selected_vehicle_snapshot[\s\S]*selected_ground_snapshot' -and
        $officialPreRequestGateFunction -match
        'Invoke-PreBaselineBacklogDrainGate[\s\S]*Test-PreRequestRecoveryBacklogPairPromotion[\s\S]*officialVehicle\s*=\s*\$recoveryPairPromotion\.selected_vehicle_snapshot[\s\S]*officialGround\s*=\s*\$recoveryPairPromotion\.selected_ground_snapshot' -and
        -not $officialPreRequestGateFunction.Contains(
          'Invoke-OfficialBaselineGate')) `
      -Detail 'Retry may adopt only the last independently revalidated two-observation stable backlog pair; the redundant full-baseline query cannot phase-lock another sentinel.'
  Add-Check -Name 'pre_request_retry_stable_pair_starts_next_m0_without_blind_recovery' `
      -Passed ($officialPreRequestGateFunction -match
        'skipNextRecoveryCapture[\s\S]*if\s*\(\$skipNextRecoveryCapture\)[\s\S]*recovery_capture_skipped_after_verified_stable_pair[\s\S]*M0_pre_request_clean_5s' -and
        $officialPreRequestGateFunction -match
        'recoveryPairPromotion\.valid[\s\S]*skipNextRecoveryCapture\s*=\s*\$true[\s\S]*continue') `
      -Detail 'A promoted pair already contains a >=5 s passive stability proof, so the next M0 starts without adding an unobserved three-second race window.'
  Add-Check -Name 'baseline_cumulative_discards_not_absolute_zero_errors' `
      -Passed (-not $baselineFunction.Contains("@(`$GroundSnapshot,'obdf')") -and
        -not $baselineFunction.Contains("@(`$GroundSnapshot,'obdb')")) `
      -Detail 'obdf/obdb must be present and continuity-checked, never absolute-zero error counters.'

  foreach ($sharedHelper in @(
      'Test-DataPlanePassiveCandidate',
      'Get-ReadinessPassiveWindowDecision',
      'Complete-ReadinessParserEpoch',
      'Complete-ReadinessParserEpochChecked',
      'Test-CaptureMatcherClean',
      'Get-ReadinessExpectedA',
      'Get-ReadinessSnapshotTransition')) {
    Add-Check -Name ('shared_helper_selftest_live_' + $sharedHelper) `
        -Passed ($selfTestFunction.Contains($sharedHelper) -and
          $readinessGateFunction.Contains($sharedHelper)) `
        -Detail 'New readiness helper must be exercised by SelfTest and invoked by the live gate.'
  }
  foreach ($sharedPostHelper in @('Get-PostDiagnosticPlan',
      'New-SyncInvalidContinuationEvidence')) {
    Add-Check -Name ('shared_helper_selftest_live_' + $sharedPostHelper) `
        -Passed ($selfTestFunction.Contains($sharedPostHelper) -and
          $source.Substring($selfGate).Contains($sharedPostHelper)) `
        -Detail 'Post-sync helper must be exercised offline and wired into the live finalization path.'
  }

  $liveSource = if ($selfGate -ge 0) {$source.Substring($selfGate)} else {''}
  Add-Check -Name 'live_raw_capture_uses_bounded_buffer_not_writethrough_hot_path' `
      -Passed ($source -match
        '\$script:RawCaptureBufferBytes\s*=\s*\[int\]65536' -and
        $source -match
        '\$script:RawCaptureFlushScheduleMs\s*=\s*\[double\]25000\.0' -and
        $source -match
        '\$script:RawCaptureFlushIntervalMs\s*=\s*\[double\]30000\.0' -and
        [regex]::Matches($liveSource,
          '\[System\.IO\.FileOptions\]::SequentialScan').Count -eq 2 -and
        [regex]::Matches($liveSource,
          '\$script:RawCaptureBufferBytes[\s\S]{0,100}' +
          '\[System\.IO\.FileOptions\]::SequentialScan').Count -eq 2) `
      -Detail 'The two live raw streams use bounded 64 KiB buffering; 25 s scheduled and 30 s hard Flush(true) boundaries retain fail-closed durability without WriteThrough in every pump slice.'
  Add-Check -Name 'passive_to_A_admin_is_parser_safe_and_checkpointed' `
      -Passed ($readinessGateFunction -match
        'passiveCandidate\s*=\s*Test-DataPlanePassiveCandidate[\s\S]*' +
        'bracketEpoch\s*=\s*New-ReadinessParserEpoch[\s\S]*' +
        'Invoke-ReadinessPumpCheckpoint[\s\S]*' +
        'RawStream\.Flush\(\$true\)[\s\S]*' +
        'Invoke-ReadinessPumpCheckpoint[\s\S]*readiness_vehicle_A_' -and
        $readinessGateFunction -match
        'readiness_pump_checkpoint_count[\s\S]*readiness_pump_checkpoints' -and
        $liveSource -match
          'boot_to_readiness_raw_boundary[\s\S]*Invoke-PumpPair[\s\S]*Invoke-DataPlaneReadinessGate') `
      -Detail 'A raw-preserving pair service spans boot-to-readiness, then a clean epoch precedes passive-to-A fsync/progress work and parser-safe checkpoints remain evidence.'
  [int]$footerWriteOffset = $liveSource.LastIndexOf(
      "'capture_footer.json'", [StringComparison]::Ordinal)
  [int]$footerFsyncOffset = $liveSource.LastIndexOf(
      "'footer_fsynced'", [StringComparison]::Ordinal)
  [int]$groundCloseOffset = $liveSource.IndexOf(
      '$groundSerial.Close()', [StringComparison]::Ordinal)
  [int]$vehicleCloseOffset = $liveSource.IndexOf(
      '$vehicleSerial.Close()', [StringComparison]::Ordinal)
  [int]$streamSealOffset = $liveSource.IndexOf(
      'Seal-EvidenceStreamsBeforeRawHash', [StringComparison]::Ordinal)
  [int]$liveAppendOffset = $liveSource.IndexOf(
      'Open-DurableJsonlAppendStream', [StringComparison]::Ordinal)
  [int]$lastPumpOffset = $liveSource.LastIndexOf(
      'Invoke-PumpPair', [StringComparison]::Ordinal)
  [int]$postFooterLiveFailureOffset = $liveSource.IndexOf(
      'post-footer live progress failure', [StringComparison]::Ordinal)
  [int]$boundWaitOffset = $liveSource.IndexOf(
      '$postPowerIdentity = Wait-ForBoundPortIdentities',
      [StringComparison]::Ordinal)
  [int]$prePowerDecisionOffset = $liveSource.IndexOf(
      '$prePowerDecision = Get-PrePowerIdentityDecision',
      [StringComparison]::Ordinal)
  [int]$prePowerStopOffset = $liveSource.IndexOf(
      'Stop-MeasuredFailure -Message $prePowerDecision.message',
      [StringComparison]::Ordinal)
  [int]$boundFoundGateOffset = $liveSource.IndexOf(
      'if (-not $postPowerIdentity.found)', [StringComparison]::Ordinal)
  [int]$portsReappearedOffset = $liveSource.IndexOf(
      "Add-TimelineEvent -Name 'ports_reappeared'",
      [StringComparison]::Ordinal)
  [int]$vehicleConstructOffset = $liveSource.IndexOf(
      '$readerBrokerBundle = Start-ReaderBrokerClient',
      [StringComparison]::Ordinal)
  [int]$vehicleOpenAfterWaitOffset = $liveSource.IndexOf(
      '$vehicleSerial.Open()', [StringComparison]::Ordinal)
  [int]$groundOpenAfterWaitOffset = $liveSource.IndexOf(
      '$groundSerial.Open()', [StringComparison]::Ordinal)
  [int]$portsOpenedOffset = $liveSource.IndexOf(
      "Add-TimelineEvent -Name 'ports_opened'",
      [StringComparison]::Ordinal)
  [int]$bootDrainOffset = $liveSource.IndexOf(
      "-Phase 'boot_observe_15s'", [StringComparison]::Ordinal)
  [int]$readinessInvokeOffset = $liveSource.IndexOf(
      '$dataPlaneReadiness = Invoke-DataPlaneReadinessGate',
      [StringComparison]::Ordinal)
  [int]$readinessGateOffset = $liveSource.IndexOf(
      'if (-not $dataPlaneReadiness.valid)', [StringComparison]::Ordinal)
  [int]$backlogDrainInvokeOffset = $liveSource.IndexOf(
      '$backlogDrainGate = Invoke-PreBaselineBacklogDrainGate',
      [StringComparison]::Ordinal)
  [int]$backlogDrainGateOffset = $liveSource.IndexOf(
      'if (-not $backlogDrainGate.valid)', [StringComparison]::Ordinal)
  [int]$baselineVehicleOffset = $liveSource.IndexOf(
      '$baselinePairGate = Invoke-OfficialBaselineGate',
      [StringComparison]::Ordinal)
  [int]$preRequestGateOffset = $liveSource.IndexOf(
      '$preRequestPairGate = Invoke-OfficialPreRequestGate',
      [StringComparison]::Ordinal)
  [int]$requestOffset = $liveSource.IndexOf(
      'Write-ExactRequestOnce -Serial $groundSerial',
      [StringComparison]::Ordinal)
  Add-Check -Name 'footer_fsync_before_both_close_lexical' `
      -Passed ($footerWriteOffset -ge 0 -and $footerFsyncOffset -gt
        $footerWriteOffset -and $groundCloseOffset -gt $footerFsyncOffset -and
        $vehicleCloseOffset -gt $footerFsyncOffset) `
      -Detail "footer=$footerWriteOffset fsync_record=$footerFsyncOffset ground_close=$groundCloseOffset vehicle_close=$vehicleCloseOffset"
  Add-Check -Name 'raw_hash_after_all_stream_dispose_before_footer' `
      -Passed ($streamSealOffset -ge 0 -and $liveAppendOffset -gt
        $streamSealOffset -and $footerWriteOffset -gt $liveAppendOffset -and
        $lastPumpOffset -lt $streamSealOffset) `
      -Detail "last_pump=$lastPumpOffset stream_seal=$streamSealOffset live_append=$liveAppendOffset footer=$footerWriteOffset"
  Add-Check -Name 'post_footer_progress_failure_not_footer_failure' `
      -Passed ($postFooterLiveFailureOffset -gt $footerWriteOffset) `
      -Detail 'footer is durably recorded before separately classified live-progress failure'
  Add-Check -Name 'live_wait_exact_binding_before_construct_open' `
      -Passed ($boundWaitOffset -ge 0 -and
        $boundFoundGateOffset -gt $boundWaitOffset -and
        $portsReappearedOffset -gt $boundFoundGateOffset -and
        $vehicleConstructOffset -gt $portsReappearedOffset -and
        $vehicleOpenAfterWaitOffset -gt $vehicleConstructOffset -and
        $groundOpenAfterWaitOffset -gt $vehicleOpenAfterWaitOffset -and
        $portsOpenedOffset -gt $groundOpenAfterWaitOffset) `
      -Detail ('wait=' + $boundWaitOffset + ' gate=' + $boundFoundGateOffset +
        ' reappeared=' + $portsReappearedOffset + ' broker_start=' +
        $vehicleConstructOffset + ' vehicle_open=' +
        $vehicleOpenAfterWaitOffset + ' ground_open=' +
        $groundOpenAfterWaitOffset + ' opened_event=' + $portsOpenedOffset)
  Add-Check -Name 'live_pre_power_decision_stops_before_wait_open' `
      -Passed ($prePowerDecisionOffset -ge 0 -and
        $prePowerStopOffset -gt $prePowerDecisionOffset -and
        $boundWaitOffset -gt $prePowerStopOffset -and
        $vehicleConstructOffset -gt $boundWaitOffset) `
      -Detail ('pre_decision=' + $prePowerDecisionOffset + ' stop=' +
        $prePowerStopOffset + ' wait=' + $boundWaitOffset + ' broker_start=' +
         $vehicleConstructOffset)
  Add-Check -Name 'live_readiness_before_baseline_pre_request_gate_request' `
      -Passed ($bootDrainOffset -gt $portsOpenedOffset -and
        $readinessInvokeOffset -gt $bootDrainOffset -and
        $readinessGateOffset -gt $readinessInvokeOffset -and
        $backlogDrainInvokeOffset -gt $readinessGateOffset -and
        $backlogDrainGateOffset -gt $backlogDrainInvokeOffset -and
        $baselineVehicleOffset -gt $backlogDrainGateOffset -and
        $preRequestGateOffset -gt $baselineVehicleOffset -and
        $requestOffset -gt $preRequestGateOffset) `
      -Detail ('opened=' + $portsOpenedOffset + ' boot=' + $bootDrainOffset +
        ' readiness=' + $readinessInvokeOffset + ' gate=' +
        $readinessGateOffset + ' backlog=' + $backlogDrainInvokeOffset +
        ' backlog_gate=' + $backlogDrainGateOffset + ' baseline=' +
        $baselineVehicleOffset + ' pre_request_gate=' +
        $preRequestGateOffset +
        ' request=' + $requestOffset)
  Add-Check -Name 'readiness_deadline_anchored_exact_ports_opened' `
      -Passed ($liveSource -match
        '\$dataPlaneReadiness\s*=\s*Invoke-DataPlaneReadinessGate[\s\S]{0,300}-GateStartedElapsedMs\s+\$portsOpenedElapsedMs') `
      -Detail 'The absolute readiness deadline is anchored to the durable ports_opened timestamp.'
  Add-Check -Name 'readiness_gate_never_queries_ground_diagnostics' `
      -Passed (-not $readinessGateFunction.Contains('VCGSTAT') -and
        -not $readinessGateFunction.Contains('$groundCommand') -and
        -not $readinessGateFunction.Contains('baseline_ground')) `
      -Detail 'Ground parser-enabled readiness windows must stay passive and never inject VCGSTAT ASCII.'
  [int]$snapshotCursorOffset = $snapshotQueryFunction.IndexOf(
      '[int]$startLineIndex = $State.TaggedLines.Count',
      [StringComparison]::Ordinal)
  [int]$snapshotWriteOffset = $snapshotQueryFunction.IndexOf(
      '$Serial.Write($Command, 0, $Command.Length)',
      [StringComparison]::Ordinal)
  [int]$snapshotCursorUseCount = [regex]::Matches(
      $snapshotQueryFunction,
      'Select-CorrelatedReport[\s\S]{0,140}-StartLineIndex\s+\$startLineIndex').Count
  Add-Check -Name 'snapshot_cursor_before_write_reused_and_exposed' `
      -Passed ($snapshotCursorOffset -ge 0 -and
        $snapshotWriteOffset -gt $snapshotCursorOffset -and
        $snapshotCursorUseCount -eq 2 -and
        $snapshotQueryFunction -match
          'tagged_line_start_index\s*=\s*\$startLineIndex') `
      -Detail ('cursor=' + $snapshotCursorOffset + ' write=' +
        $snapshotWriteOffset + ' select_uses=' + $snapshotCursorUseCount)
  [int]$snapshotRawBoundaryUseCount = [regex]::Matches(
      $snapshotQueryFunction,
      'Select-CorrelatedReport[\s\S]{0,180}-MinimumRawStartOffset\s+\$startRawOffset').Count
  Add-Check -Name 'snapshot_cursor_also_requires_raw_start_boundary' `
      -Passed ($snapshotRawBoundaryUseCount -eq 2 -and
        $correlatedStateFunction -match
          'MinimumRawStartOffset[\s\S]*Select-CorrelatedReportFromRows[\s\S]*-MinimumRawStartOffset\s+\$MinimumRawStartOffset' -and
        $correlatedRowsFunction -match
          'MinimumRawStartOffset[\s\S]*candidate\.raw_start_offset[\s\S]*-lt\s+\$MinimumRawStartOffset[\s\S]*continue') `
      -Detail ('select_raw_boundary_uses=' + $snapshotRawBoundaryUseCount +
        '; line cursor alone cannot admit a pre-query partial completed after the cursor snapshot')
  Add-Check -Name 'diagnostic_query_counter_not_decorative' `
      -Passed ([regex]::Matches($source,
          '\+\+\$script:DiagnosticQueryWriteCount').Count -eq 2 -and
        $liveSource -match
          '\$script:DiagnosticQueryWriteCount\s*=\s*\[uint64\]0[\s\S]*Invoke-SnapshotQuery') `
      -Detail 'The only two counter increments are immediately after the two successful Serial.Write branches, with live zero initialization.'
  [int]$passiveCaptureOffset = $readinessGateFunction.IndexOf(
      "data_plane_readiness_passive_window_", [StringComparison]::Ordinal)
  [int]$passiveCandidateOffset = $readinessGateFunction.IndexOf(
      '$passiveCandidate = Test-DataPlanePassiveCandidate',
      [StringComparison]::Ordinal)
  [int]$aQueryOffset = $readinessGateFunction.IndexOf(
      "readiness_vehicle_A_", [StringComparison]::Ordinal)
  [int]$aTransitionOffset = $readinessGateFunction.IndexOf(
      '$vehicleATransition = Get-ReadinessSnapshotTransition',
      [StringComparison]::Ordinal)
  [int]$aPostQueryMatcherOffset = $readinessGateFunction.IndexOf(
      '$vehicleAPostQueryMatcher = Get-CaptureMatcherSnapshot',
      [StringComparison]::Ordinal)
  [int]$aResponseOffset = $readinessGateFunction.IndexOf(
      '$vehicleAResponse = $vehicleATransition.response',
      [StringComparison]::Ordinal)
  [int]$aRejectOffset = $readinessGateFunction.IndexOf(
      'if (-not $vehicleATransition.valid)', [StringComparison]::Ordinal)
  [int]$readinessWindowOffset = $readinessGateFunction.IndexOf(
      "data_plane_readiness_window_", [StringComparison]::Ordinal)
  [int]$bQueryOffset = $readinessGateFunction.IndexOf(
      "readiness_vehicle_B_", [StringComparison]::Ordinal)
  [int]$bTransitionOffset = $readinessGateFunction.IndexOf(
      '$vehicleBTransition = Get-ReadinessSnapshotTransition',
      [StringComparison]::Ordinal)
  [int]$bPostQueryMatcherOffset = $readinessGateFunction.IndexOf(
      '$vehicleBPostQueryMatcher = Get-CaptureMatcherSnapshot',
      [StringComparison]::Ordinal)
  [int]$bResponseOffset = $readinessGateFunction.IndexOf(
      '$vehicleBResponse = $vehicleBTransition.response',
      [StringComparison]::Ordinal)
  [int]$bRejectOffset = $readinessGateFunction.IndexOf(
      'if (-not $vehicleBTransition.valid)', [StringComparison]::Ordinal)
  [int]$windowAssessmentOffset = $readinessGateFunction.IndexOf(
      '$windowAssessment = Test-DataPlaneReadinessWindow',
      [StringComparison]::Ordinal)
  [int]$completeBSeedOffset = $readinessGateFunction.IndexOf(
      '$lastCompleteVehicleB = $vehicleB',
      [StringComparison]::Ordinal)
  Add-Check -Name 'live_passive_then_A_window_B_generation_order' `
      -Passed ($passiveCaptureOffset -ge 0 -and
        $passiveCandidateOffset -gt $passiveCaptureOffset -and
        $aQueryOffset -gt $passiveCandidateOffset -and
        $aTransitionOffset -gt $aQueryOffset -and
        $aResponseOffset -gt $aTransitionOffset -and
        $aRejectOffset -gt $aResponseOffset -and
        $readinessWindowOffset -gt $aRejectOffset -and
        $bQueryOffset -gt $readinessWindowOffset -and
        $bTransitionOffset -gt $bQueryOffset -and
        $bResponseOffset -gt $bTransitionOffset -and
        $bRejectOffset -gt $bResponseOffset -and
        $completeBSeedOffset -gt $bRejectOffset -and
        $windowAssessmentOffset -gt $completeBSeedOffset) `
      -Detail ('passive=' + $passiveCaptureOffset + ' candidate=' +
        $passiveCandidateOffset + ' A_query=' + $aQueryOffset +
        ' A_transition=' + $aTransitionOffset +
        ' A_response=' + $aResponseOffset + ' A_reject=' +
        $aRejectOffset + ' window=' + $readinessWindowOffset +
        ' B_query=' + $bQueryOffset + ' B_transition=' +
        $bTransitionOffset + ' B_response=' + $bResponseOffset +
        ' B_reject=' + $bRejectOffset + ' B_seed=' +
        $completeBSeedOffset + ' assessment=' + $windowAssessmentOffset)
  Add-Check -Name 'A_B_transition_uses_immediate_post_query_matcher' `
      -Passed ($aPostQueryMatcherOffset -gt $aQueryOffset -and
        $aTransitionOffset -gt $aPostQueryMatcherOffset -and
        $bPostQueryMatcherOffset -gt $bQueryOffset -and
        $bTransitionOffset -gt $bPostQueryMatcherOffset -and
        $readinessGateFunction -match
          '\$vehicleATransition\s*=\s*Get-ReadinessSnapshotTransition[\s\S]{0,650}-PreQueryMatcherSnapshot\s+\$vehicleAMatcherGate\.snapshot[\s\S]{0,180}-MatcherSnapshot\s+\$vehicleAPostQueryMatcher' -and
        $readinessGateFunction -match
          '\$vehicleBTransition\s*=\s*Get-ReadinessSnapshotTransition[\s\S]{0,650}-PreQueryMatcherSnapshot\s+\$vehicleBMatcherGate\.snapshot[\s\S]{0,180}-MatcherSnapshot\s+\$vehicleBPostQueryMatcher') `
      -Detail ('A_query=' + $aQueryOffset + ' A_post=' +
        $aPostQueryMatcherOffset + ' A_transition=' + $aTransitionOffset +
        ' B_query=' + $bQueryOffset + ' B_post=' +
        $bPostQueryMatcherOffset + ' B_transition=' + $bTransitionOffset)
  Add-Check -Name 'A_B_prewrite_and_postquery_matchers_are_distinct' `
      -Passed ($readinessGateFunction.Contains('$vehicleAMatcherGate') -and
        $readinessGateFunction.Contains('$vehicleBMatcherGate') -and
        $readinessGateFunction.Contains('$vehicleAPostQueryMatcher') -and
        $readinessGateFunction.Contains('$vehicleBPostQueryMatcher') -and
        $readinessGateFunction -match
          'vehicle_A_matcher_after_query\s*=\s*\$vehicleATransition\.matcher_after_query' -and
        $readinessGateFunction -match
          'vehicle_B_matcher_after_query\s*=\s*\$vehicleBTransition\.matcher_after_query') `
      -Detail 'Pre-write cleanliness evidence remains distinct from immediate post-query matcher state; complete A/B window rows preserve both post-query states.'
  Add-Check -Name 'snapshot_transition_preserves_post_query_matcher' `
      -Passed ([regex]::Matches($snapshotTransitionFunction,
          'matcher_after_query\s*=\s*\$MatcherSnapshot').Count -eq 2 -and
        $snapshotTransitionFunction -match
          'PreQueryMatcherSnapshot[\s\S]*pending_byte_count[\s\S]*overflow_count[\s\S]*post_query_matcher_dirty[\s\S]*New-ReadinessSyncInvalidLatch[\s\S]*-MatcherSnapshot\s+\$MatcherSnapshot') `
      -Detail 'Both invalid and valid transitions expose the exact post-query matcher snapshot; invalid transitions also freeze it in the latch.'
  $passiveParserCloseMatch = [regex]::Match($readinessGateFunction,
      '\$passiveEpochResult\s*=\s*Complete-ReadinessParserEpochChecked[\s\S]{0,900}-Stage\s+''passive_prefilter''[\s\S]{0,250}-MatcherSnapshot\s+\(Get-CaptureMatcherSnapshot\s+-State\s+\$GroundState\)')
  $passiveParserRejectMatch = [regex]::Match($readinessGateFunction,
      'if\s*\(\$passiveCandidate\.sync_invalid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$passiveParserRejectBody = if ($passiveParserRejectMatch.Success) {
    [string]$passiveParserRejectMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'passive_parser_corruption_latches_before_queries' `
      -Passed ($passiveParserCloseMatch.Success -and
        $passiveParserRejectMatch.Success -and
        $passiveParserRejectBody.Contains('$groundSyncInvalid') -and
        $passiveParserRejectBody.Contains('$syncInvalid = $true') -and
        $passiveParserRejectBody.Contains('$passiveEpochResult.ground_sync_invalid') -and
        -not $passiveParserRejectBody.Contains('Invoke-SnapshotQuery') -and
        -not $passiveParserRejectBody.Contains('$VehicleCommand')) `
      -Detail 'Parser corruption is a Ground sync-invalid latch and cannot be hidden by retries or diagnostic queries.'
  $passiveRetryMatch = [regex]::Match($readinessGateFunction,
      'if\s*\(-not\s+\$passiveCandidate\.candidate\)(?<body>[\s\S]*?)\bcontinue\b')
  [string]$passiveRetryBody = if ($passiveRetryMatch.Success) {
    [string]$passiveRetryMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'passive_noncandidate_retries_without_queries' `
      -Passed ($passiveRetryMatch.Success -and
        -not $passiveRetryBody.Contains('Invoke-SnapshotQuery') -and
        -not $passiveRetryBody.Contains('$VehicleCommand') -and
        -not $passiveRetryBody.Contains('$Serial.Write') -and
        -not $passiveRetryBody.Contains('Write-ExactRequestOnce')) `
      -Detail 'HB absence/wrong source/count/edge-tail retries another passive window with Vehicle query count zero.'
  Add-Check -Name 'passive_and_bracket_param_events_copied_before_reset' `
      -Passed ([regex]::Matches($readinessGateFunction,
          'Complete-ReadinessParserEpoch').Count -ge 4 -and
        $readinessGateFunction -match
          'data_plane_readiness_passive_window[\s\S]*Complete-ReadinessParserEpoch[\s\S]*readiness_vehicle_A[\s\S]*readiness_vehicle_B[\s\S]*Complete-ReadinessParserEpoch[\s\S]*finally[\s\S]*Complete-ReadinessParserEpoch') `
      -Detail 'Passive, normal bracket, A/B reject, and finally paths all close the parser epoch through one idempotent #22-harvest/reset helper.'
  Add-Check -Name 'passive_boundary_pump_idle_harvest_reset_then_start' `
      -Passed ($readinessGateFunction -match
        'New-ReadinessParserEpoch[\s\S]*Invoke-PumpPairUntilIdle[\s\S]{0,500}-AbsoluteDeadlineElapsedMs\s+\$deadlineElapsedMs[\s\S]*Complete-ReadinessParserEpoch[\s\S]*if\s*\(-not\s+\$idleResult\.idle\)[\s\S]*\$timedOut\s*=\s*\$true[\s\S]*break[\s\S]*passiveStartRawOffset[\s\S]*passiveStartMs[\s\S]*New-ReadinessParserEpoch[\s\S]*data_plane_readiness_passive_window') `
      -Detail 'Each passive observation begins only after pump-to-idle and lossless pre-boundary #22 harvest/reset.'
  $readinessGateCommandNames = @()
  if ($readinessGateDefinitions.Count -eq 1) {
    $readinessGateCommandNames = @(
      $readinessGateDefinitions[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
      }, $true) | ForEach-Object {$_.GetCommandName()})
  }
  [int]$uncheckedEpochCloseCount = @($readinessGateCommandNames |
    Where-Object {$_ -ceq 'Complete-ReadinessParserEpoch'}).Count
  [int]$checkedEpochCloseCount = @($readinessGateCommandNames |
    Where-Object {$_ -ceq 'Complete-ReadinessParserEpochChecked'}).Count
  Add-Check -Name 'all_live_readiness_epoch_closes_are_integrity_checked' `
      -Passed ($uncheckedEpochCloseCount -eq 0 -and
        $checkedEpochCloseCount -eq 11 -and
        $checkedParserEpochFunction -match
          'Complete-ReadinessParserEpoch[\s\S]*integrity\.valid[\s\S]*New-ReadinessSyncInvalidLatch[\s\S]*role[\s\S]*ground[\s\S]*sync_invalid') `
      -Detail ('checked=' + $checkedEpochCloseCount +
        ' unchecked=' + $uncheckedEpochCloseCount)
  $boundaryIntegrityMatch = [regex]::Match($readinessGateFunction,
      '\$boundaryEpochResult\s*=\s*Complete-ReadinessParserEpochChecked[\s\S]{0,900}if\s*\(\$boundaryEpochResult\.sync_invalid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$boundaryIntegrityBody = if ($boundaryIntegrityMatch.Success) {
    [string]$boundaryIntegrityMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'boot_boundary_corruption_stops_before_passive_and_queries' `
      -Passed ($boundaryIntegrityMatch.Success -and
        $boundaryIntegrityBody -match
          'groundSyncInvalid[\s\S]*syncInvalid\s*=\s*\$true' -and
        -not $boundaryIntegrityBody.Contains('Invoke-SnapshotQuery') -and
        -not $boundaryIntegrityBody.Contains('$VehicleCommand')) `
      -Detail 'Pump-to-idle parser corruption is Ground sync-invalid before a passive epoch or any Vehicle query.'
  Add-Check -Name 'deadline_and_finally_epoch_closes_preserve_corruption' `
      -Passed ($readinessGateFunction -match
        'if\s*\(-not\s+\$aBudget\.can_query\)[\s\S]*Complete-ReadinessParserEpochChecked[\s\S]*sync_invalid[\s\S]*break' -and
        $readinessGateFunction -match
        'if\s*\(-not\s+\$windowCapture\.completed_duration\)[\s\S]*Complete-ReadinessParserEpochChecked[\s\S]*sync_invalid[\s\S]*break' -and
        $readinessGateFunction -match
        'if\s*\(-not\s+\$bBudget\.can_query\)[\s\S]*Complete-ReadinessParserEpochChecked[\s\S]*sync_invalid[\s\S]*break' -and
        $readinessGateFunction -match
        'finally[\s\S]*Complete-ReadinessParserEpochChecked[\s\S]*sync_invalid[\s\S]*groundSyncInvalid') `
      -Detail 'A-budget, short-window, B-budget, and finally close paths must prioritize Ground corruption over an ordinary timeout.'
  Add-Check -Name 'A_and_B_require_clean_matcher_before_write' `
      -Passed ($readinessGateFunction -match
        '\$vehicleAMatcherGate\s*=\s*Test-CaptureMatcherClean[\s\S]*if\s*\(-not\s+\$vehicleAMatcherGate\.valid\)[\s\S]*break[\s\S]*readiness_vehicle_A[\s\S]*\$vehicleBMatcherGate\s*=\s*Test-CaptureMatcherClean[\s\S]*if\s*\(-not\s+\$vehicleBMatcherGate\.valid\)[\s\S]*break[\s\S]*readiness_vehicle_B') `
      -Detail 'A and B writes are both suppressed if any preexisting partial matcher bytes or overflow delta exist.'
  $aDirtyMatcherBranch = [regex]::Match($readinessGateFunction,
      'if\s*\(-not\s+\$vehicleAMatcherGate\.valid\)(?<body>[\s\S]*?)\bbreak\b')
  $bDirtyMatcherBranch = [regex]::Match($readinessGateFunction,
      'if\s*\(-not\s+\$vehicleBMatcherGate\.valid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$aDirtyMatcherBody = if ($aDirtyMatcherBranch.Success) {
    [string]$aDirtyMatcherBranch.Groups['body'].Value
  } else { '' }
  [string]$bDirtyMatcherBody = if ($bDirtyMatcherBranch.Success) {
    [string]$bDirtyMatcherBranch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'A_B_dirty_matcher_latches_exact_bytes_no_query' `
      -Passed ($aDirtyMatcherBranch.Success -and
        $aDirtyMatcherBody -match
          'vehicleSyncInvalid[\s\S]*matcher_at_latch[\s\S]*vehicleAMatcherGate\.snapshot' -and
        $bDirtyMatcherBranch.Success -and
        $bDirtyMatcherBody -match
          'vehicleSyncInvalid[\s\S]*matcher_at_latch[\s\S]*vehicleBMatcherGate\.snapshot') `
      -Detail 'Preexisting A/B partial bytes are frozen as exact matcher evidence before query suppression.'
  Add-Check -Name 'complete_B_seed_and_valid_bracket_seed_are_separate' `
      -Passed ($readinessGateFunction.Contains('$lastCompleteVehicleB') -and
        $readinessGateFunction.Contains('$lastVehicleSnapshot') -and
        $readinessGateFunction -match
          '\$expectedA\s*=\s*Get-ReadinessExpectedA[\s\S]*\$lastCompleteVehicleB\s*=\s*\$vehicleB[\s\S]*\$windowAssessment[\s\S]*\$lastVehicleSnapshot\s*=\s*Select-ReadinessLastVehicleSnapshot') `
      -Detail 'Every exact B advances only the next-A q seed; only a valid bracket advances the downstream Vehicle snapshot.'
  [string]$aToBText = if ($aQueryOffset -ge 0 -and
      $bQueryOffset -gt $aQueryOffset) {
    $readinessGateFunction.Substring($aQueryOffset,
        $bQueryOffset - $aQueryOffset)
  } else { '' }
  [int]$bracketEpochOffset = $readinessGateFunction.IndexOf(
      '$bracketEpoch = New-ReadinessParserEpoch',
      [StringComparison]::Ordinal)
  [string]$bracketToAText = if ($bracketEpochOffset -ge 0 -and
      $aQueryOffset -gt $bracketEpochOffset) {
    $readinessGateFunction.Substring($bracketEpochOffset,
        $aQueryOffset - $bracketEpochOffset)
  } else { '' }
  Add-Check -Name 'A_to_B_ground_parser_epoch_continuous' `
      -Passed ($bracketToAText.Contains('$GroundParser.Enabled = $true') -and
         -not $aToBText.Contains('$GroundParser.Enabled = $false') -and
         -not $aToBText.Contains('Reset-MavlinkAnalysis') -and
         $readinessGateFunction -match
           'readiness_vehicle_B[\s\S]*\$bracketEpochResult\s*=\s*Complete-ReadinessParserEpoch') `
      -Detail 'Ground parser remains enabled/unreset on the success path over A, the fresh five-second window, and B; reject branches close through the shared helper.'
  $bracketIntegrityMatch = [regex]::Match($readinessGateFunction,
      '\$bracketEpochResult\s*=\s*Complete-ReadinessParserEpochChecked[\s\S]{0,900}if\s*\(-not\s+\$bracketEpochResult\.integrity\.valid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$bracketIntegrityBody = if ($bracketIntegrityMatch.Success) {
    [string]$bracketIntegrityMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'bracket_parser_corruption_is_ground_sync_invalid' `
      -Passed ($bracketIntegrityMatch.Success -and
        $bracketIntegrityBody -match
          'groundSyncInvalid[\s\S]*syncInvalid\s*=\s*\$true') `
      -Detail 'CRC/noise/partial corruption anywhere in A-window-B latches Ground sync-invalid rather than retrying.'
  $aRejectMatch = [regex]::Match($readinessGateFunction,
      'if\s*\(-not\s+\$vehicleATransition\.valid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$aRejectBody = if ($aRejectMatch.Success) {
    [string]$aRejectMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'A_rejects_before_window_B_and_preserves_last' `
      -Passed ($aRejectMatch.Success -and
        $aRejectBody.Contains("failure='vehicle_A_invalid_or_timeout'") -and
        $aRejectBody.Contains('$syncInvalid = $true') -and
        $aRejectBody.Contains('$vehicleSyncInvalid =') -and
        $aRejectBody.Contains('$vehicleATransition.sync_invalid_latch') -and
        -not $aRejectBody.Contains('Invoke-CaptureInterval') -and
        -not $aRejectBody.Contains('Invoke-SnapshotQuery') -and
        -not $aRejectBody.Contains('$lastCompleteVehicleB')) `
      -Detail 'Invalid/timeout/COMPLETE-dirty A transition latches matcher/correlation state and terminates before the fresh window or B query.'
  $bRejectMatch = [regex]::Match($readinessGateFunction,
      'if\s*\(-not\s+\$vehicleBTransition\.valid\)(?<body>[\s\S]*?)\bbreak\b')
  [string]$bRejectBody = if ($bRejectMatch.Success) {
    [string]$bRejectMatch.Groups['body'].Value
  } else { '' }
  Add-Check -Name 'B_reject_latches_before_cursor_assessment' `
      -Passed ($bRejectMatch.Success -and
        $bRejectBody.Contains("failure='vehicle_B_invalid_or_timeout'") -and
        $bRejectBody.Contains('$syncInvalid = $true') -and
        $bRejectBody.Contains('$vehicleSyncInvalid =') -and
        $bRejectBody.Contains('$vehicleBTransition.sync_invalid_latch') -and
        -not $bRejectBody.Contains('$lastCompleteVehicleB') -and
        -not $bRejectBody.Contains('Test-DataPlaneReadinessWindow')) `
      -Detail 'Invalid/timeout/COMPLETE-dirty B transition latches matcher/correlation state before cursor or assessment mutation.'
  Add-Check -Name 'post_vehicle_suppressed_on_readiness_sync_invalid' `
      -Passed ($liveSource -match
        '\$postDiagnosticPlan\s*=\s*Get-PostDiagnosticPlan[\s\S]{0,900}if\s*\(\$postDiagnosticPlan\.run_ground\)[\s\S]{0,900}Invoke-SnapshotQuery\s+-Name\s+''post_ground''[\s\S]{0,1200}New-SyncInvalidSuppressedSnapshot[\s\S]{0,900}if\s*\(\$postDiagnosticPlan\.run_vehicle\)[\s\S]{0,900}Invoke-SnapshotQuery\s+-Name\s+''post_vehicle''[\s\S]{0,1200}New-SyncInvalidSuppressedSnapshot') `
      -Detail 'Role-specific readiness sync-invalid and backlog sync-invalid use an explicit plan to suppress every unsafe post query.'
  Add-Check -Name 'sync_invalid_footer_pump_preserves_matcher_continuation' `
      -Passed ($liveSource -match
        'if\s*\(\$postDiagnosticPlan\.any_sync_invalid\)[\s\S]*Get-CaptureMatcherSnapshot[\s\S]*DiagnosticQueryWriteCount[\s\S]*Invoke-CaptureInterval\s+-Milliseconds\s+250\s+-Phase\s+''footer_drain''[\s\S]*Get-CaptureMatcherSnapshot[\s\S]*New-SyncInvalidContinuationEvidence[\s\S]*sync_invalid_continuation\.json') `
      -Detail 'The passive footer pump records exact matcher/raw/tag state before and after, with zero diagnostic writes.'
  Assert-SourcePattern -Name 'official_baseline_gate_shares_backlog_deadline' `
      -Pattern '\$baselinePairGate\s*=\s*Invoke-OfficialBaselineGate[\s\S]{0,700}-DeadlineElapsedMs\s+\$backlogDrainGate\.deadline_elapsed_ms[\s\S]{0,500}-InitialVehicleSnapshot\s+\$backlogDrainGate\.last_vehicle_snapshot[\s\S]{0,300}-InitialGroundSnapshot\s+\$backlogDrainGate\.last_ground_snapshot' `
      -Description 'Official baseline retry must reuse, never extend, the backlog-drain absolute deadline and seed both role chains from its final pair.'
  Assert-SourcePattern -Name 'official_baseline_gate_selects_only_valid_final_pair' `
      -Pattern '\$baselineVehicle\s*=\s*\$baselinePairGate\.final_vehicle_snapshot[\s\S]{0,250}\$baselineGround\s*=\s*\$baselinePairGate\.final_ground_snapshot[\s\S]{0,250}\$baselineSetup\s*=\s*\$baselinePairGate\.baseline_setup[\s\S]{0,900}if\s*\(-not\s+\$baselinePairGate\.valid\)[\s\S]{0,1400}else\s*\{[\s\S]{0,800}Invoke-OfficialPreRequestGate' `
      -Description 'Only a final fully valid reconciled pair may enter the bounded pre-request gate; retry exhaustion remains setup-invalid/write-zero.'
  Assert-SourcePattern -Name 'official_pre_request_gate_shares_backlog_deadline' `
      -Pattern '\$preRequestPairGate\s*=\s*Invoke-OfficialPreRequestGate[\s\S]{0,900}-DeadlineElapsedMs\s+\$backlogDrainGate\.deadline_elapsed_ms[\s\S]{0,500}-InitialVehicleSnapshot\s+\$baselineVehicle[\s\S]{0,300}-InitialGroundSnapshot\s+\$baselineGround' `
      -Description 'Every M0 retry, backlog resynchronization, and re-baseline remains inside the original backlog absolute deadline.'
  Add-Check -Name 'm0_requires_primary_hb_and_clean_parser' `
      -Passed ($m0GateFunction -match
        'Get-ParserIntegrity[\s\S]*ParamList\.events\.Count[\s\S]*Get-HeartbeatWindowMetrics[\s\S]*preRequestIntegrity\.valid[\s\S]*preRequestParamValues\s+-eq\s+0[\s\S]*m0Heartbeat\.valid[\s\S]*m0Heartbeat\.count\s+-ge\s+2' -and
        $officialPreRequestGateFunction -match
        '\$causalGate\s*=\s*Test-M0CausalGate') `
      -Detail 'AST-scoped M0 helper and bounded gate require parser clean, zero #22, and at least two primary heartbeats for final acceptance.'
  Add-Check -Name 'm0_backlog_gate_requires_completed_epoch' `
      -Passed ($m0GateFunction -match
        'Test-PreRequestBacklogGate[\s\S]*-M0EpochCompleted\s+\$true' -and
        $officialPreRequestGateFunction -match
        'Test-PreRequestBacklogGate[\s\S]{0,350}-M0Events\s+@\(\)\s+-M0EpochCompleted\s+\$false') `
      -Detail 'A real M0 marks the epoch complete; fallback evidence cannot turn an unrun empty epoch into PASS.'
  Add-Check -Name 'm0_attempt_has_one_vehicle_recheck_no_ground_query_sleep' `
      -Passed ([regex]::Matches($officialPreRequestGateFunction,
          'Invoke-SnapshotQuery').Count -eq 1 -and
        $officialPreRequestGateFunction.Contains("pre_request_vehicle") -and
        $officialPreRequestGateFunction.Contains('-Serial $VehicleSerial') -and
        $officialPreRequestGateFunction.Contains('-Command $VehicleCommand') -and
        -not $officialPreRequestGateFunction.Contains('Start-Sleep') -and
        -not $officialPreRequestGateFunction.Contains(
          'Write-ExactRequestOnce')) `
      -Detail 'Each loop iteration has one textual Vehicle-only TOCTOU query; Ground recovery is delegated to bounded helpers and #21 is outside this gate.'
  Add-Check -Name 'm0_tail_and_vehicle_recheck_recomputed_before_disposition' `
      -Passed ($officialPreRequestGateFunction -match
        'M0_pre_request_clean_5s[\s\S]*\$preRequestVehicle\s*=\s*Invoke-SnapshotQuery[\s\S]*Invoke-PumpPair[\s\S]*Test-PreRequestVehicleGate[\s\S]*Test-M0CausalGate[\s\S]*Get-PreRequestAttemptDisposition') `
      -Detail 'After the sole per-attempt Vehicle recheck, final pump feeds both TOCTOU and HB/backlog gates before ACCEPT/RETRY/REJECT.'
  Add-Check -Name 'pre_request_retry_reacquires_stable_pair_before_new_m0' `
      -Passed ($officialPreRequestGateFunction -match
        'Get-PreRequestAttemptDisposition[\s\S]*RETRY[\s\S]*Invoke-PreBaselineBacklogDrainGate[\s\S]*Test-PreRequestRecoveryBacklogPairPromotion[\s\S]*continue' -and
        $officialPreRequestGateFunction -match
        'Invoke-PreBaselineBacklogDrainGate[\s\S]{0,900}-AbsoluteDeadlineElapsedMs\s+\$DeadlineElapsedMs') `
      -Detail 'An exact sentinel race never becomes PASS: it obtains and revalidates two strict stable observations under the original deadline before a new clean M0.'
  Add-Check -Name 'request_suppressed_post_contract_is_explicitly_not_run' `
      -Passed ($requestSuppressedPostFunction -match
        'NOT_RUN_REQUEST_SUPPRESSED[\s\S]*evaluated\s*=\s*\$false[\s\S]*fixture_write_count[\s\S]*request_attempt_count' -and
        $liveSource -match
        'if\s*\(\s*(?:\[int\])?\$injection\.attempt_count\s+-eq\s+1\s+-and\s+(?:\[int\])?\$injection\.write_count\s+-eq\s+1\s+-and\s+-not\s+(?:\[bool\])?\$injection\.write_uncertain\s+-and\s+(?:\[string\])?\$injection\.write_disposition\s+-ceq\s+''ACKNOWLEDGED_EXACTLY_ONCE''\s*\)[\s\S]*Test-PostSnapshotContract[\s\S]*else[\s\S]*New-RequestSuppressedPostAssessment' -and
        $liveSource -match
        'post diagnostic contract failed[\s\S]*post_snapshots') `
      -Detail 'Only attempt1/write1/non-uncertain/ACKNOWLEDGED_EXACTLY_ONCE may run the +1/+932 success contract; every other injection state keeps post snapshots diagnostic-only and explicitly NOT_RUN.'
  Assert-SourcePattern -Name 'pre_request_gate_valid_only_then_fixture_write' `
      -Pattern '\$preRequestPairGate\s*=\s*Invoke-OfficialPreRequestGate[\s\S]{0,1800}\$postVehicleAnchor[\s\S]{0,1200}if\s*\(-not\s+\$preRequestPairGate\.valid\)[\s\S]{0,1800}\}\s*else\s*\{[\s\S]{0,900}capture_scope\s*=\s*''official''[\s\S]{0,900}Write-ExactRequestOnce' `
      -Description 'Retry/reject paths keep fixture_write_count=0; only a final clean M0 plus strict Vehicle gate reaches the sole #21 writer.'
  Add-Check -Name 'post_vehicle_q_anchor_uses_latest_complete_pre_request' `
      -Passed ($liveSource -match
        '\$postVehicleAnchor\s*=\s*\$baselineVehicle' -and
        $liveSource -match
        '\$preRequestPairGate\.latest_complete_vehicle_snapshot[\s\S]{0,500}\$postVehicleAnchor\s*=\s*\$preRequestPairGate\.latest_complete_vehicle_snapshot' -and
        $liveSource -match
        'Get-NextQueryId[\s\S]{0,180}-Snapshot\s+\$postVehicleAnchor' -and
        $liveSource -match
        'Test-PostSnapshotContract[\s\S]{0,500}-Baseline\s+\$postVehicleAnchor') `
      -Detail 'Even when M0 is rejected, post Vehicle q correlation advances from the latest complete pre-request snapshot rather than the stale official baseline.'
  $captureLoopMatch = [regex]::Match($liveSource,
      'while\s*\(-not\s+\$captureLoopDone\)(?<body>[\s\S]*?)\$m1\s*=')
  [string]$captureLoopBody = if ($captureLoopMatch.Success) {
    [string]$captureLoopMatch.Groups['body'].Value
  } else { '' }
  $heartbeatAccumulatorDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'New-HeartbeatWindowAccumulator'
    }, $true))
  $heartbeatAccumulatorUpdateDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Update-HeartbeatWindowAccumulator'
    }, $true))
  $heartbeatAccumulatorSnapshotDefinitions = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Get-HeartbeatWindowAccumulatorSnapshot'
    }, $true))
  [string]$heartbeatAccumulatorUpdateSource =
      if ($heartbeatAccumulatorUpdateDefinitions.Count -eq 1) {
        [string]$heartbeatAccumulatorUpdateDefinitions[0].Extent.Text
      } else { '' }
  [string]$heartbeatAccumulatorSnapshotSource =
      if ($heartbeatAccumulatorSnapshotDefinitions.Count -eq 1) {
        [string]$heartbeatAccumulatorSnapshotDefinitions[0].Extent.Text
      } else { '' }
  Add-Check -Name 'heartbeat_incremental_accumulator_is_bounded_per_new_event' `
      -Passed ($heartbeatAccumulatorDefinitions.Count -eq 1 -and
        $heartbeatAccumulatorUpdateDefinitions.Count -eq 1 -and
        $heartbeatAccumulatorSnapshotDefinitions.Count -eq 1 -and
        $heartbeatAccumulatorUpdateSource -match
          'next_event_index[\s\S]*while[\s\S]*Events\.Count[\s\S]*next_event_index' -and
        -not $heartbeatAccumulatorUpdateSource.Contains('Sort-Object') -and
        -not $heartbeatAccumulatorUpdateSource.Contains('Where-Object') -and
        -not $heartbeatAccumulatorSnapshotSource.Contains('Sort-Object') -and
        -not $heartbeatAccumulatorSnapshotSource.Contains('Where-Object')) `
      -Detail 'The live accumulator consumes each newly appended heartbeat once; neither update nor snapshot rescans/sorts full history.'
  Add-Check -Name 'capture_loop_has_no_full_history_heartbeat_recompute' `
      -Passed ($captureLoopMatch.Success -and
        -not $captureLoopBody.Contains('Get-HeartbeatWindowMetrics') -and
        $captureLoopBody.Contains('Update-HeartbeatWindowAccumulator') -and
        [regex]::Matches($captureLoopBody,
          'Update-HeartbeatWindowAccumulator').Count -eq 1 -and
        [regex]::Matches($captureLoopBody,
          'Get-HeartbeatWindowAccumulatorSnapshot').Count -eq 1 -and
        $captureLoopBody -match
          'if\s*\(\$progressDue\)[\s\S]{0,600}' +
          'Get-HeartbeatWindowAccumulatorSnapshot[\s\S]{0,900}' +
          'Write-ProgressIfDue') `
      -Detail 'Every R0 pump turn updates only newly appended heartbeats; an O(1), gap-free snapshot is allocated only when progress is due.'
  Add-Check -Name 'official_heartbeat_metrics_include_incremental_gap_evidence' `
      -Passed ($liveSource -match
        '\$m1\s*=\s*\[pscustomobject\][\s\S]{0,900}Update-HeartbeatWindowAccumulator[\s\S]{0,500}Get-HeartbeatWindowAccumulatorSnapshot[\s\S]{0,300}-IncludeGaps') `
      -Detail 'The M1 assessment performs one final incremental update and materializes complete edge/consecutive/tail evidence exactly once.'
  Add-Check -Name 'semantic_anomaly_not_immediate_capture_terminal' `
      -Passed ($captureLoopMatch.Success -and
        -not $captureLoopBody.Contains('$semanticFatal') -and
        $captureLoopBody.Contains('$groundParser.ParamList.next_expected_index -eq 932') -and
        $captureLoopBody.Contains('$timeoutDecision.stall_timeout') -and
        $captureLoopBody.Contains('$timeoutDecision.overall_timeout')) `
      -Detail 'Semantic counters remain fail-closed evidence but only 932+guard, existing stall, or overall timeout ends official capture.'
  Assert-SourcePattern -Name 'official_cutoff_frozen_before_post_cutoff_pump' `
      -Pattern '\$m1\s*=\s*\[pscustomobject\][\s\S]{0,1200}\$officialParamListState\s*=\s*\$groundParser\.ParamList[\s\S]{0,1500}\$groundParser\.ParamList\s*=\s*New-ParamListState[\s\S]{0,150}-CaptureScope\s+''post_cutoff''[\s\S]{0,400}\$script:CurrentPhase\s*=\s*''post_cutoff_drain''[\s\S]{0,500}Invoke-PumpPair' `
      -Description 'M1/official state and assessments are frozen before a separately scoped final diagnostic pump.'
  Assert-SourcePattern -Name 'param_list_diagnostic_artifact_written' `
      -Pattern 'New-ParamListDiagnosticEvidence[\s\S]{0,1000}param_list_diagnostics\.json[\s\S]{0,300}Write-JsonDurable' `
      -Description 'Durable diagnostic artifact covers backlog, official cutoff, post-cutoff events, and proxy terminal state.'
  Assert-SourcePattern `
      -Name 'exception_safe_finalization_projections_initialized_before_main_try' `
      -Pattern '\$rawEvidenceSeal\s*=\s*Get-RawEvidenceFallbackProjection[\s\S]{0,500}\$pumpFairnessEvidence\s*=\s*Get-PumpFairnessFallbackProjection[\s\S]{0,1400}\$backlogDrainGate\s*=\s*\$null[\s\S]{0,200}\$backlogDrainEvidence\s*=\s*Get-BacklogDrainEvidenceProjection' `
      -Description 'Raw, pump, and backlog projections are complete fail-closed objects before the live main try can throw.'
  Assert-SourcePattern `
      -Name 'completed_backlog_gate_promoted_immediately_for_exception_path' `
      -Pattern '\$backlogDrainGate\s*=\s*Invoke-PreBaselineBacklogDrainGate[\s\S]{0,900}\$backlogDrainEvidence\s*=\s*Get-BacklogDrainEvidenceProjection\s+`?[\s\S]{0,220}-BacklogDrainGate\s+\$backlogDrainGate' `
      -Description 'A completed backlog gate is promoted before any later diagnostic or cleanup failure.'
  Assert-SourcePattern `
      -Name 'footer_failure_preserves_primary_and_exact_once_evidence' `
      -Pattern '\$footerFailureResolution\s*=\s*Resolve-FinalizationFailure[\s\S]{0,300}-PrimaryFailure\s+\$failure[\s\S]{0,300}\$failure\s*=\s*\[string\]\$footerFailureResolution\.primary_failure[\s\S]{0,1000}primary_failure\s*=\s*\$failure[\s\S]{0,600}fixture_write_count\s*=\s*\[int\]\$injection\.write_count' `
      -Description 'STOP_CAPTURE/footer failure is secondary; the first exception and exact-once state remain durable.'
  Assert-SourcePattern `
      -Name 'postclose_failure_artifact_preserves_primary_and_exact_once_evidence' `
      -Pattern '\$postCloseFailureResolution\s*=\s*Resolve-FinalizationFailure[\s\S]{0,400}\$failure\s*=\s*\[string\]\$postCloseFailureResolution\.primary_failure[\s\S]{0,1000}postclose_finalization_error\.json[\s\S]{0,700}primary_failure\s*=\s*\$failure[\s\S]{0,500}fixture_write_count\s*=\s*\[int\]\$injection\.write_count' `
      -Description 'Even a later summary/hash exception records the original failure and exact-once request state.'
  Assert-SourcePattern `
      -Name 'summary_raw_and_pump_fallbacks_are_explicit_fail_closed' `
      -Pattern 'raw_capture\s*=\s*\[ordered\]@\{[\s\S]{0,200}seal_valid\s*=\s*\[bool\]\$rawEvidenceSeal\.seal_valid[\s\S]{0,900}pump_fairness\s*=\s*\$pumpFairnessEvidence' `
      -Description 'The post-close summary serializes incomplete raw/pump evidence explicitly instead of dereferencing null.'
  Assert-SourcePattern `
      -Name 'r5c_primary_error_regression_selfcase_present' `
      -Pattern "Add-SelfCase\s+'post_ground_closed_then_shutdown_failure_preserves_primary'" `
      -Description 'Offline regression covers COM-closed primary plus broken-pipe shutdown and end-to-end summary serialization.'

  $childRuns = New-Object 'System.Collections.Generic.List[object]'
  foreach ($scenarioSpec in @(
      @('pass', 'PASS', 0, 'PASS'),
      @('measured_fail', 'MEASURED_FAIL', 1, 'FAIL'),
      @('power_off_timeout', 'POWER_OFF_TIMEOUT', 1, 'FAIL'),
      @('readiness_timeout', 'READINESS_TIMEOUT', 1, 'FAIL'),
      @('readiness_sync_invalid', 'READINESS_SYNC_INVALID', 1, 'FAIL'),
      @('postclose_error', 'POSTCLOSE_ERROR', 2, 'ERROR'))) {
    [string]$scenarioName = [string]($scenarioSpec[0])
    [string]$scenarioArgument = [string]($scenarioSpec[1])
    [int]$expectedExit = [int]($scenarioSpec[2])
    [string]$expectedStatus = [string]($scenarioSpec[3])
    $selfEvidence = Join-Path $EvidenceDirectory `
        ('runner_selftest_' + $scenarioName)
    $stdoutFile = Join-Path $EvidenceDirectory `
        ('child_' + $scenarioName + '_stdout.tmp')
    $stderrFile = Join-Path $EvidenceDirectory `
        ('child_' + $scenarioName + '_stderr.tmp')
    [string]$runnerChildPreSha = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $RunnerPath).Hash
    [long]$runnerChildPreSize = (Get-Item -LiteralPath $RunnerPath).Length
    [string]$checkerChildPreSha = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $checkerPath).Hash
    [long]$checkerChildPreSize = (Get-Item -LiteralPath $checkerPath).Length
    [string]$savedErrorPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      ++$runnerChildProcessStartCount
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RunnerPath `
          -SelfTest -SelfTestScenario $scenarioArgument `
          -VehiclePort COM999 -GroundPort COM998 `
          -SelfTestEvidenceDirectory $selfEvidence `
          1> $stdoutFile 2> $stderrFile
      [int]$scenarioExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $savedErrorPreference
    }
    [string]$runnerChildPostSha = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $RunnerPath).Hash
    [long]$runnerChildPostSize = (Get-Item -LiteralPath $RunnerPath).Length
    [string]$checkerChildPostSha = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $checkerPath).Hash
    [long]$checkerChildPostSize = (Get-Item -LiteralPath $checkerPath).Length
    [bool]$runnerChildSourceExact = (
        $runnerChildPreSha -ceq $runnerInitialSha256 -and
        $runnerChildPostSha -ceq $runnerInitialSha256 -and
        $runnerChildPreSize -eq $runnerInitialSize -and
        $runnerChildPostSize -eq $runnerInitialSize)
    [bool]$checkerChildSourceExact = (
        $checkerChildPreSha -ceq $checkerSha256 -and
        $checkerChildPostSha -ceq $checkerSha256 -and
        $checkerChildPreSize -eq $checkerInitialSize -and
        $checkerChildPostSize -eq $checkerInitialSize)
    Add-Check -Name ('selftest_' + $scenarioName +
        '_runner_source_bound_unchanged') `
        -Passed $runnerChildSourceExact `
        -Detail ('pre=' + $runnerChildPreSha + ' post=' +
          $runnerChildPostSha + ' pinned=' + $runnerInitialSha256)
    Add-Check -Name ('selftest_' + $scenarioName +
        '_checker_source_bound_unchanged') `
        -Passed $checkerChildSourceExact `
        -Detail ('pre=' + $checkerChildPreSha + ' post=' +
          $checkerChildPostSha + ' pinned=' + $checkerSha256)
    [string]$scenarioStdout = if (Test-Path -LiteralPath $stdoutFile) {
      Get-Content -Raw -LiteralPath $stdoutFile
    } else { '' }
    [string]$scenarioStderr = if (Test-Path -LiteralPath $stderrFile) {
      Get-Content -Raw -LiteralPath $stderrFile
    } else { '' }
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force `
        -ErrorAction SilentlyContinue
    $childStdout += "[$scenarioName]`n$scenarioStdout`n"
    $childStderr += "[$scenarioName]`n$scenarioStderr`n"
    Add-Check -Name ('runner_selftest_' + $scenarioName + '_exit') `
        -Passed ($scenarioExit -eq $expectedExit) `
        -Detail "actual=$scenarioExit expected=$expectedExit invalid_ports=COM999/COM998"
    Add-Check -Name ('runner_selftest_' + $scenarioName + '_final_line') `
        -Passed ($scenarioStdout -match
          ("FINAL {0} output=" -f $expectedStatus)) `
        -Detail 'Child stdout must expose final status and evidence path.'

    $selfSummaryPath = Join-Path $selfEvidence 'selftest_summary.json'
    $selfSummaryExists = Test-Path -LiteralPath $selfSummaryPath -PathType Leaf
    Add-Check -Name ('selftest_' + $scenarioName + '_summary_exists') `
        -Passed $selfSummaryExists -Detail $selfSummaryPath
    $selfSummary = $null
    if ($selfSummaryExists) {
      $selfSummary = Get-Content -Raw -LiteralPath $selfSummaryPath |
          ConvertFrom-Json
      Add-Check -Name ('selftest_' + $scenarioName + '_status') `
          -Passed ([string]$selfSummary.status -eq $expectedStatus) `
          -Detail "actual=$($selfSummary.status) expected=$expectedStatus"
      foreach ($counterName in @('serial_enumeration_count',
          'serial_port_construction_count', 'serial_open_count',
          'request_write_count', 'upload_count')) {
        $property = $selfSummary.PSObject.Properties[$counterName]
        [bool]$isZero = ($null -ne $property -and
            [long]$property.Value -eq 0)
        Add-Check -Name ('selftest_' + $scenarioName + '_' +
            $counterName + '_zero') -Passed $isZero `
            -Detail "$counterName must be zero"
      }
      $taggedElapsedProbePath = Join-Path $selfEvidence `
          'tagged_elapsed_runtime_probe.json'
      [bool]$taggedElapsedProbeValid = $false
      [string]$taggedElapsedProbeDetail = 'missing'
      if (Test-Path -LiteralPath $taggedElapsedProbePath -PathType Leaf) {
        try {
          $taggedElapsedProbe = Get-Content -Raw `
              -LiteralPath $taggedElapsedProbePath | ConvertFrom-Json
          $taggedElapsedProbeValid = (
            [bool]$taggedElapsedProbe.passed -and
            [int]$taggedElapsedProbe.function_definition_count -eq 3 -and
            [int]$taggedElapsedProbe.explicit.line_count -eq 1 -and
            [double]$taggedElapsedProbe.explicit.elapsed_ms -eq 123.456 -and
            [int]$taggedElapsedProbe.implicit.line_count -eq 1 -and
            [double]$taggedElapsedProbe.implicit.elapsed_ms -ge 0.0 -and
            [int]$taggedElapsedProbe.serial_enumeration_count -eq 0 -and
            [int]$taggedElapsedProbe.serial_port_construction_count -eq 0 -and
            [int]$taggedElapsedProbe.serial_open_count -eq 0 -and
            [string]::IsNullOrEmpty(
              [string]$taggedElapsedProbe.error))
          $taggedElapsedProbeDetail =
              'explicit=' + $taggedElapsedProbe.explicit.elapsed_ms +
              ' implicit=' + $taggedElapsedProbe.implicit.elapsed_ms +
              ' error=' + [string]$taggedElapsedProbe.error
        } catch {
          $taggedElapsedProbeDetail = $_.Exception.GetType().FullName +
              ': ' + $_.Exception.Message
        }
      }
      Add-Check -Name ('selftest_' + $scenarioName +
          '_tagged_elapsed_live_path_runtime') `
          -Passed $taggedElapsedProbeValid `
          -Detail $taggedElapsedProbeDetail
      foreach ($caseName in @(
          'fixture_exact','fixture_bitflip','fixture_wrong_message',
          'fixture_wrong_source','fixture_wrong_target','fixture_wrong_length',
          'fixture_signed','write_exact_once','identity_exact_pass',
          'identity_wrong_rejected','identity_role_swap_rejected',
          'identity_empty_inventory_valid_false_no_error',
          'identity_null_inventory_rejected',
          'wait_reappear_empty_then_exact',
          'wait_reappear_wrong_inventory_timeout',
          'wait_reappear_malformed_inventory_timeout',
          'wait_reappear_ports_open_progression',
          'wait_reappear_first_valid_poll_does_not_bind',
          'wait_reappear_invalid_poll_resets_stability_window',
          'wait_reappear_continuous_exact_5000ms_enables_open',
          'reader_broker_open_start_ioexception_surfaces_exact_error',
          'pre_power_empty_measured_fail_suppressed',
          'ps51_generic_param_event_enumeration_0_1_n',
          'tagged_elapsed_expression_ps51_runtime',
          'serial_read_slice_bounds_32_bytes',
          'reader_worker_asymmetric_flood_lossless',
          'reader_worker_overflow_fail_closed_no_overwrite',
          'reader_worker_producer_timestamp_not_consumer_time',
          'reader_worker_shutdown_barrier_exact',
          'reader_broker_full_gc_process_isolated',
          'reader_broker_350ms_admin_block_strict_fairness',
          'reader_broker_asymmetric_flood_lossless',
          'reader_broker_overflow_fail_closed_no_overwrite',
          'reader_broker_producer_timestamp_not_consumer_time',
          'reader_broker_inflight_barrier_shutdown_exact',
          'reader_broker_inflight_barrier_cross_role_fairness',
          'reader_broker_violation_trace_bounded_consistent',
          'reader_broker_multichunk_1500_lossless',
          'reader_broker_exact_fixture_once_flush_ack',
          'reader_broker_write_uncertainty_no_retry',
          'reader_broker_fatal_rejects_mutation_cleanup',
          'reader_broker_windows_argv_roundtrip',
          'reader_broker_two_stage_close_lifecycle',
          'reader_broker_strict_config_mismatch_preopen',
          'reader_broker_numeric_context_schema',
          'raw_capture_hot_path_bounded_buffered_not_writethrough',
          'readiness_passive_to_A_parser_safe_pump_checkpoints',
          'passive_prefilter_no_hb_vehicle_query_zero',
          'passive_prefilter_wrong_source_vehicle_query_zero',
          'passive_prefilter_one_hb_vehicle_query_zero',
          'passive_prefilter_stale_edge_tail_vehicle_query_zero',
          'passive_prefilter_parser_errors_vehicle_query_zero',
          'passive_prefilter_parser_corruption_sync_invalid',
          'passive_prefilter_pump_idle_boundary',
          'passive_prefilter_idle_timeout_vehicle_query_zero',
          'passive_prefilter_candidate_measured_boundaries',
          'passive_prefilter_delayed_candidate_one_A_B',
          'readiness_invalid_assessment_returns_to_passive',
          'readiness_invalid_assessment_next_A_from_complete_B',
          'readiness_complete_B_cursor_advances_on_invalid_assessment',
          'readiness_B_cursor_excludes_prequery_expected_group',
          'readiness_B_cursor_ignores_delayed_A_selects_fresh_B',
          'snapshot_cursor_rejects_prequery_raw_start',
          'snapshot_cursor_accepts_boundary_raw_start',
          'passive_prefilter_param22_retained',
          'readiness_param22_harvest_exact_all_exit_paths',
          'readiness_epoch_raw_offsets_unique_ordered',
          'readiness_boot_boundary_corruption_sync_invalid',
          'readiness_A_budget_close_corruption_sync_invalid',
          'readiness_window_incomplete_close_corruption_sync_invalid',
          'readiness_B_budget_close_corruption_sync_invalid',
          'readiness_finally_close_corruption_sync_invalid',
          'readiness_epoch_corruption_both_post_suppressed',
          'passive_prefilter_hard_720_deadline',
          'readiness_A_preexisting_partial_query_zero',
          'readiness_B_preexisting_partial_query_zero',
          'readiness_matcher_pending_bytes_exact_latch',
          'readiness_A_timeout_sync_invalid_state',
          'readiness_A_write_timeout_sync_invalid_state',
          'readiness_A_wrong_q_sync_invalid_state',
          'readiness_B_timeout_sync_invalid_state',
          'readiness_B_write_timeout_sync_invalid_state',
          'readiness_B_wrong_q_sync_invalid_state',
          'readiness_A_post_query_partial_timeout_latch_exact',
          'readiness_B_post_query_partial_timeout_latch_exact',
          'readiness_post_query_partial_survives_suppression_footer',
          'readiness_A_post_query_overflow_latch_exact',
          'readiness_B_post_query_overflow_latch_exact',
          'readiness_post_query_overflow_survives_suppression_footer',
          'readiness_A_complete_with_trailing_partial_rejected',
          'readiness_B_complete_with_trailing_partial_rejected',
          'readiness_A_B_parser_epoch_continuous',
          'readiness_bracket_parser_corruption_sync_invalid',
          'readiness_sync_invalid_post_vehicle_suppressed',
          'readiness_sync_invalid_both_post_suppressed',
          'readiness_sync_invalid_matcher_state_preserved',
          'readiness_sync_invalid_footer_continuation_zero_writes',
          'post_diagnostics_sync_invalid_matrix',
          'param_diagnostic_nested_empty_arrays_typed',
          'param_diagnostic_nested_events_0_1_n_arrays',
          'sync_invalid_suppressed_snapshot_text_exact',
          'readiness_evidence_boolean_types_and_raw_literals',
          'diagnostic_query_counter_successful_write_only',
          'readiness_no_heartbeat_clean_rejected',
          'readiness_hb_only_rejected','readiness_d7_only_rejected',
          'readiness_wrong_source_rejected',
          'readiness_one_heartbeat_tail_rejected',
          'readiness_stale_hb_outside_window_rejected',
          'readiness_parser_error_rejected','readiness_delayed_valid',
          'readiness_parser_noise_partial_rejected',
          'readiness_boot_change_rejected','readiness_q_stale_rejected',
          'readiness_counter_decrease_rejected',
          'readiness_A_hang_deadline_rejected',
          'readiness_B_hang_deadline_clamped',
          'readiness_absolute_deadline_no_second_rounding',
          'readiness_B_write_timeout_clamped',
          'readiness_absolute_deadline_flush_eliminated',
          'readiness_write_margin_boundary_rejected',
          'readiness_B_usb_wake_R3_exact_97_byte_partial',
          'readiness_B_usb_wake_stall_249_999_ms',
          'readiness_B_usb_wake_stall_250_ms',
          'readiness_B_usb_wake_remaining_599_999_ms',
          'readiness_B_usb_wake_remaining_600_ms',
          'readiness_B_usb_wake_second_attempt',
          'readiness_B_usb_wake_opt_out',
          'readiness_B_usb_wake_ground_role',
          'readiness_B_usb_wake_missing_expected_q',
          'readiness_B_usb_wake_query_not_written',
          'readiness_B_usb_wake_query_write_timed_out',
          'readiness_B_usb_wake_report_already_complete',
          'readiness_B_usb_wake_wrong_q_prefix',
          'readiness_B_usb_wake_short_prefix',
          'readiness_B_usb_wake_VCSTAT2_prefix',
          'readiness_B_usb_wake_canonical_field_order_changed',
          'readiness_B_usb_wake_nonprintable_byte',
          'readiness_B_usb_wake_preexisting_partial_matcher',
          'readiness_B_usb_wake_overflow_delta',
          'readiness_B_usb_wake_tagged_line_progress',
          'readiness_B_usb_wake_raw_discontinuity',
          'readiness_B_usb_wake_constants_frozen',
          'readiness_B_usb_wake_same_q_complete_keeps_window',
          'readiness_B_usb_wake_failure_stays_sync_invalid',
          'readiness_A_timeout_skips_window_B',
          'readiness_A_delayed_B_stale_rejected',
          'readiness_last_snapshot_only_valid_bracket',
          'readiness_device_ms_brackets_5s',
          'readiness_timeout_deadline_from_ports_opened',
          'readiness_timeout_boundary_no_short_window',
          'readiness_timeout_setup_invalid_fail1',
          'baseline_vehicle_d7f_zero_rejected',
          'baseline_ground_rfv_zero_rejected',
          'baseline_ground_usbacc_zero_rejected',
          'baseline_demux_buffer_nonzero_rejected',
          'baseline_demux_escape_mode_disabled_rejected',
          'm0_clean_but_dead_rejected',
          'baseline_native_diagnostic_keys_present_pass',
          'baseline_vehicle_native_diagnostic_key_missing_rejected',
          'baseline_ground_native_diagnostic_key_missing_rejected',
          'baseline_stale_generic_reconciliation_rejected',
          'baseline_vehicle_pgq_nonzero_rejected',
          'baseline_vehicle_pga_nonzero_rejected',
          'baseline_vehicle_prq_nonzero_rejected',
          'baseline_vehicle_ptq_nonzero_rejected',
          'baseline_normal_rb1_ew3_allowed',
          'baseline_normal_obf2_obb42_allowed',
          'baseline_cumulative_discard_nonzero_allowed',
          'baseline_ground_backlog_nonempty_rejected',
          'baseline_related_drop_error_rejected',
          'backlog_drain_current_mismatch_retries',
          'backlog_drain_delayed_stable_pass',
          'backlog_partial_snapshot_retryable_with_shared_deadline',
          'backlog_partial_snapshot_resync_same_boot_monotonic',
          'backlog_partial_snapshot_recovery_resets_stable_pair',
          'backlog_partial_snapshot_overflow_not_retryable',
          'backlog_partial_snapshot_retry_exhausted_write0',
          'backlog_partial_snapshot_shared_deadline_no_extension',
          'backlog_initial_ground_recovery_null_previous_safe',
          'backlog_initial_ground_recovery_null_expected_q_reachable',
          'backlog_unanchored_recovery_guard_fail_closed',
          'backlog_recovery_reject_preserves_pre_reset_matcher',
          'backlog_drain_cumulative_discard_stable_pass',
          'backlog_drain_cumulative_discard_increment_rejected',
          'backlog_drain_to_baseline_cumulative_discard_stable_pass',
          'backlog_drain_to_baseline_cumulative_discard_increment_rejected',
          'backlog_drain_to_baseline_cumulative_discard_missing_rejected',
          'baseline_param22_ground_ahead_one_retryable',
          'baseline_param22_retry_then_reconciled_pass',
          'baseline_param22_persistent_mismatch_retry_exhausted_write0',
          'baseline_param22_unsafe_mismatch_not_retryable',
          'baseline_exact_stat_runtime_race_retryable',
          'baseline_unknown_or_indexed_sentinel_not_retryable',
          'baseline_stale_or_unproven_stat_runtime_not_retryable',
          'baseline_stat_runtime_plus_other_failure_not_retryable',
          'baseline_stat_runtime_retry_bounded_by_deadline_and_attempts',
          'baseline_stat_runtime_retry_then_full_pair_clean_pass',
          'baseline_exact_stat_runtime_vehicle_ahead_race_retryable',
          'baseline_stat_runtime_vehicle_ahead_failure_set_order_independent',
          'baseline_stat_runtime_vehicle_ahead_d7pb_bounds_1_279_retryable',
          'baseline_stat_runtime_vehicle_ahead_d7pb_out_of_range_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_tuple_variants_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_stale_pvms_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_counter_shape_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_queue_or_activity_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_error_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_boot_or_discard_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_failure_set_not_exact_not_retryable',
          'baseline_stat_runtime_vehicle_ahead_retry_bounded_deadline_attempts_write0',
          'baseline_stat_runtime_vehicle_ahead_retry_then_full_pair_clean_pass',
          'baseline_R1_reconciled_stat_runtime_active_partial_d7_retryable',
          'baseline_R1_active_partial_failure_set_order_independent',
          'baseline_R1_active_partial_pga_exact_one_and_pga0_route_preserved',
          'baseline_R1_active_partial_nonexact_not_retryable',
          'baseline_R1_active_partial_retry_bounded_write0',
          'baseline_R1_active_partial_retry_then_clean_pair_pass',
          'baseline_R3_stat_runtime_vehicle_ahead_empty_d7_retryable',
          'baseline_R3_vehicle_ahead_empty_failure_set_order_independent',
          'baseline_R3_vehicle_ahead_empty_d7_exact_zero_and_partial_route_preserved',
          'baseline_R3_vehicle_ahead_empty_nonexact_not_retryable',
          'baseline_R3_vehicle_ahead_empty_retry_bounded_write0',
          'baseline_R3_vehicle_ahead_empty_retry_then_clean_pair_pass',
          'baseline_retry_wrong_q_sync_invalid_write0',
          'baseline_retry_shared_deadline_no_extension',
          'baseline_retry_sync_invalid_both_post_suppressed',
          'backlog_drain_timeout_write0',
          'backlog_drain_two_observations_5s',
          'pre_request_vehicle_clean_pass',
          'pre_request_vehicle_boot_change_rejected',
          'pre_request_vehicle_d722_increase_rejected',
          'pre_request_vehicle_reconciliation_rejected',
           'pre_request_vehicle_queue_nonzero_rejected',
           'pre_request_vehicle_d7pb_nonzero_rejected',
           'pre_request_exact_stat_runtime_retryable',
           'pre_request_exact_stat_runtime_active_frame_retryable',
           'pre_request_exact_stat_runtime_active_d7pb_nonzero_not_retryable',
           'pre_request_exact_stat_runtime_active_pga_gt_one_not_retryable',
           'pre_request_exact_stat_runtime_active_queue_shape_not_retryable',
           'pre_request_exact_stat_runtime_active_event_shape_not_retryable',
           'pre_request_exact_stat_runtime_active_other_queue_or_error_not_retryable',
           'pre_request_exact_stat_runtime_active_attempt_or_deadline_bounded_write0',
           'pre_request_exact_stat_runtime_active_retry_then_stable_pair_reacquisition',
           'pre_request_silent_stat_runtime_queued_pgq1_pga0_retryable',
           'pre_request_silent_stat_runtime_queued_exact_failure_set_and_baseline_d7pb_drained',
           'pre_request_silent_stat_runtime_queued_unknown_indexed_crc_partial_not_retryable',
           'pre_request_silent_stat_runtime_queued_other_queue_or_error_not_retryable',
           'pre_request_silent_stat_runtime_queued_attempt_or_deadline_bounded_write0',
           'pre_request_silent_stat_runtime_queued_retry_then_stable_pair_reacquisition',
           'pre_request_unknown_or_indexed_not_retryable',
           'pre_request_stat_runtime_plus_parser_or_hb_failure_not_retryable',
           'pre_request_stat_runtime_retry_then_clean_pass',
           'pre_request_stat_runtime_retry_exhausted_write0',
           'pre_request_retry_shared_deadline_no_extension',
           'pre_request_stat_runtime_retry_fixture0_until_clean',
           'pre_request_silent_stat_runtime_inflight_retryable',
           'pre_request_silent_stat_runtime_inflight_exact_failure_set',
           'pre_request_silent_stat_runtime_inflight_failure_set_order_independent_retryable',
           'pre_request_silent_stat_runtime_inflight_official_boot_zero_not_retryable',
           'pre_request_silent_stat_runtime_inflight_current_boot_zero_not_retryable',
           'pre_request_silent_stat_runtime_inflight_boot_change_not_retryable',
           'pre_request_silent_stat_runtime_inflight_m0_epoch_incomplete_not_retryable',
           'pre_request_silent_stat_runtime_inflight_tuple_or_freshness_not_retryable',
           'pre_request_silent_stat_runtime_inflight_delta_not_one_not_retryable',
           'pre_request_silent_stat_runtime_inflight_queue_or_error_not_retryable',
           'pre_request_silent_stat_runtime_inflight_parser_or_hb_not_retryable',
           'pre_request_silent_stat_runtime_inflight_any_m0_event_not_retryable',
           'pre_request_silent_stat_runtime_inflight_attempt_or_deadline_bounded_write0',
           'pre_request_silent_stat_runtime_inflight_retry_then_clean_pass',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_bounds_1_279_retry_only_write0',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_280_not_retryable',
           'pre_request_silent_stat_runtime_inflight_official_d7pb_nonzero_not_retryable',
           'pre_request_r7_stat_runtime_two_heartbeat_gap_prior_partial_retry_only_write0',
           'pre_request_r7_gap_nonheartbeat_noncontiguous_or_payload_mismatch_not_retryable',
           'pre_request_r7_gap_crc_false_not_retryable',
           'pre_request_r7_gap_null_event_rejected_without_throw',
           'pre_request_r7_gap_missing_wire_or_partial_bound_not_retryable',
           'pre_request_r7_gap_any_crc_error_not_retryable',
           'pre_request_r7_gap_attempt_deadline_bounded_write0',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_capture_incomplete_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_missing_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_multiple_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_crc_invalid_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_parser_integrity_not_clean_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_raw_range_invalid_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_sequence_mismatch_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_tuple_mismatch_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_source_mismatch_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_boundary_mismatch_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_pre_m0_tail_m0_event_nonzero_not_retryable',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_attempt_or_deadline_bounded_write0',
           'pre_request_silent_stat_runtime_inflight_partial_d7pb_retry_then_clean_d7pb0_accept',
           'pre_request_observed_stat_runtime_partial_d7_shadow_retryable',
           'pre_request_observed_stat_runtime_partial_d7_exact_failure_and_correlation',
           'pre_request_observed_stat_runtime_partial_d7_event_shape_not_retryable',
           'pre_request_observed_stat_runtime_partial_d7_unknown_indexed_multiple_not_retryable',
           'pre_request_observed_stat_runtime_partial_d7_causal_shape_not_retryable',
           'pre_request_observed_stat_runtime_partial_d7_observer_delta_not_retryable',
           'pre_request_observed_stat_runtime_partial_d7_bounds_and_official_empty',
           'pre_request_observed_stat_runtime_partial_d7_queue_or_error_not_retryable',
           'pre_request_observed_stat_runtime_partial_d7_attempt3_or_deadline_write0',
           'pre_request_observed_stat_runtime_partial_d7_retry_then_attempt3_clean_accept',
           'pre_request_isolated_partial_d7_attempt3_arms_extra_write0',
           'pre_request_isolated_partial_d7_bounds_and_fail_closed',
           'pre_request_isolated_partial_d7_dedicated_budget_single_use_write0',
           'pre_request_isolated_partial_d7_attempt4_clean_accept_write0',
           'pre_request_isolated_partial_d7_attempt4_nonclean_rejected_write0',
           'pre_request_exact_wire_stat_runtime_attempt3_arms_extra_write0',
           'pre_request_exact_wire_stat_runtime_extra_near_miss_silent_faults_rejected',
           'pre_request_exact_wire_stat_runtime_attempt4_clean_accept_write0',
           'pre_request_exact_wire_stat_runtime_attempt4_recurrence_rejected_write0',
           'pre_request_dedicated_extra_token_mutually_exclusive_total4',
           'pre_request_retry_stable_backlog_pair_promoted',
           'pre_request_retry_stale_or_nonfinal_pair_rejected_write0',
           'pre_request_retry_promoted_pair_d722_rf22_mismatch_rejected_write0',
           'pre_request_retry_invalid_gate_or_continuity_rejected_write0',
           'pre_request_periodic_stat_runtime_promoted_pair_then_clean_m0_pass',
           'pre_request_direct_snapshot_invalid_sync_latched',
          'post_vehicle_anchor_advances_through_retry_recovery_snapshots',
          'post_vehicle_anchor_uses_latest_complete_pre_request',
           'post_request_suppressed_assessment_not_run',
           'post_request_suppressed_complete_snapshots_are_diagnostic_only',
           'post_acknowledged_exactly_once_enables_success_contract',
           'post_uncertain_or_nonack_success_contract_not_run',
           'post_acknowledged_once_missing_u21_still_rejected',
          'm0_reject_disables_resets_parser',
          'baseline_post_diagnostics','post_diagnostic_error_rejected',
           'post_native_fence_poison_clean_pass',
           'post_native_precommit_quarantine_exact_subset_pass',
           'post_native_precommit_quarantine_mismatch_rejected',
           'post_native_hard_zero_nonzero_rejected',
           'post_native_preexisting_abnormal_zero_delta_rejected',
           'post_native_r5_classified_stat_runtime_pass',
           'post_native_classification_missing_field_rejected',
           'post_native_classification_partition_mutations_rejected',
           'post_native_cancelled_frame_bytes_mutations_rejected',
           'post_native_unexpected_latch_mutations_rejected',
           'post_native_snuid_format_mutations_rejected',
           'post_native_d722_partition_mutation_rejected',
           'post_native_target_lane_mutations_rejected',
           'post_native_filter_timing_mutations_rejected',
           'post_native_fence_count_not_one_rejected',
           'post_native_frames_queued_931_933_rejected',
           'vehicle_hb_grant_diag_hgd_zero_delta_allowed',
           'vehicle_hb_grant_diag_hgd_positive_delta_allowed',
           'vehicle_hb_grant_diag_missing_or_nonuint64_rejected',
           'vehicle_hb_grant_diag_decrease_rejected',
           'vehicle_hb_grant_diag_hdm_delta_nonzero_rejected',
           'vehicle_hb_grant_diag_requires_exact_vcstat3',
           'vehicle_hb_grant_diag_uint64_max_supported',
           'positive_932','positive_932_mavlink_sequence_wraps',
          'duplicate_param_id','empty_param_id','duplicate','missing',
          'out_of_order','out_of_range','wrong_source','wrong_count',
          'known_sentinel_allowed','unknown_sentinel','extra_param_value',
          'semantic_unknown_sentinel_continues_to_complete',
          'semantic_extra_frame_continues_through_guard',
          'semantic_anomaly_does_not_reset_stall',
          'first_anomaly_metadata_frozen',
          'param_event_cap_truncation_error',
          'pre_request_backlog_clean_pass',
          'pre_request_backlog_readiness_audited_not_blocking',
          'pre_request_backlog_m0_not_completed_rejected',
          'pre_request_backlog_m0_rejected',
          'pre_request_backlog_known_sentinel_audited_not_blocking',
          'official_post_cutoff_separated',
          'post_cutoff_does_not_mutate_official',
          'param_list_diagnostic_schema',
          'diagnostic_stop_reason_proxy_terminal',
           'heartbeat_edge','heartbeat_consecutive','heartbeat_tail',
           'heartbeat_incremental_matches_full_history',
           'reader_clock_anchor_contemporaneous_after_delay',
           'reader_clock_anchor_qual008_finalization_regression',
           'reader_clock_anchor_fairness_start_propagation',
           'duplicate_guard_tail_heartbeat','heartbeat_gap_rejected',
          'parser_integrity','parser_unsupported_id',
          'parser_unsupported_flags','parser_bad_length','parser_bad_crc',
          'parser_noise','parser_partial','stall','overall_timeout',
          'stall_invalid_progress_no_reset','long_counter_boundaries',
           'progress_format','progress_idle_safe',
           'preopen_power_off_timeout_finalize',
           'live_progress_durable_order','durable_empty_failure',
           'durable_json_empty_array_exact',
           'durable_json_array_cardinality_preserved',
           'durable_json_nonarray_bytes_unchanged')) {
        $case = @($selfSummary.cases | Where-Object {
            $_.name -eq $caseName })
        [bool]$casePass = ($case.Count -eq 1 -and
            [bool]($case[0].passed))
        Add-Check -Name ('selftest_' + $scenarioName + '_case_' +
            $caseName) -Passed $casePass `
            -Detail "Required independently named offline case: $caseName"
      }
    }

    $readerBrokerHarnessPath = Join-Path $selfEvidence `
        'reader_broker_harness.json'
    [bool]$barrierCrossRoleFairnessValid = $false
    [bool]$brokerViolationTraceValid = $false
    [string]$barrierCrossRoleFairnessDetail = 'artifact missing'
    [string]$brokerViolationTraceDetail = 'artifact missing'
    if (Test-Path -LiteralPath $readerBrokerHarnessPath -PathType Leaf) {
      try {
        $readerBrokerHarness = Get-Content -Raw -LiteralPath `
            $readerBrokerHarnessPath | ConvertFrom-Json
        $barrierHarness = $readerBrokerHarness.harness.barrier
        [object[]]$barrierRecords = @($barrierHarness.records)
        $barrierTransition = $barrierHarness.transition_barrier
        $barrierVehicle = $barrierHarness.stop.Vehicle
        $barrierGround = $barrierHarness.stop.Ground
        $barrierCrossRoleFairnessValid = (
          [bool]$barrierHarness.exact_inflight_inclusion -and
          [long]$barrierTransition.Vehicle.SequenceExclusive -eq 1 -and
          [long]$barrierTransition.Vehicle.RawOffsetExclusive -eq 32 -and
          $barrierRecords.Count -eq 2 -and
          [long]$barrierRecords[0].Sequence -eq 0 -and
          [long]$barrierRecords[0].RawStartOffset -eq 0 -and
          [int]$barrierRecords[0].Count -eq 32 -and
          [uint32]$barrierRecords[0].ContextId -eq [uint32]0 -and
          [string]$barrierRecords[0].ProducerPhase -ceq 'ports_opening' -and
          [string]$barrierRecords[0].ProducerEpoch -ceq 'boot_observe' -and
          [long]$barrierRecords[1].Sequence -eq 1 -and
          [long]$barrierRecords[1].RawStartOffset -eq 32 -and
          [int]$barrierRecords[1].Count -eq 32 -and
          [uint32]$barrierRecords[1].ContextId -eq [uint32]1 -and
          [string]$barrierRecords[1].ProducerPhase -ceq
              'after_inflight_barrier' -and
          [string]$barrierRecords[1].ProducerEpoch -ceq
              'epoch_after_inflight_barrier' -and
          [double]$barrierGround.MaxServiceGapMs -lt 100.0 -and
          [double]$barrierGround.MaxReadDurationMs -lt 100.0 -and
          [long]$barrierGround.ServiceGapOverHardLimitCount -eq 0 -and
          [long]$barrierGround.ReadDurationOverHardLimitCount -eq 0)
        $barrierCrossRoleFairnessDetail = (
          'exact=' + [bool]$barrierHarness.exact_inflight_inclusion +
          ' vehicle_boundary=' +
          [long]$barrierTransition.Vehicle.SequenceExclusive + '/' +
          [long]$barrierTransition.Vehicle.RawOffsetExclusive +
          ' records=' + $barrierRecords.Count +
          ' ground_gap_ms=' +
          [double]$barrierGround.MaxServiceGapMs +
          ' ground_read_ms=' +
          [double]$barrierGround.MaxReadDurationMs +
          ' ground_gap_hard=' +
          [long]$barrierGround.ServiceGapOverHardLimitCount +
          ' ground_read_hard=' +
          [long]$barrierGround.ReadDurationOverHardLimitCount)

        [bool]$tracePropertiesPresent = $true
        foreach ($traceRole in @($barrierVehicle,$barrierGround)) {
          foreach ($traceProperty in @('ViolationEventCap',
              'ViolationEventCount','ViolationEventTotalCount',
              'ViolationEventOverflowCount','ViolationEvents')) {
            if ($null -eq $traceRole.PSObject.Properties[$traceProperty]) {
              $tracePropertiesPresent = $false
            }
          }
        }
        if ($tracePropertiesPresent) {
          [bool]$allRoleTracesValid = $true
          foreach ($traceRole in @($barrierVehicle,$barrierGround)) {
            [object[]]$traceEvents = @($traceRole.ViolationEvents)
            [long]$expectedTraceTotal =
                [long]$traceRole.ServiceGapOverTargetCount +
                [long]$traceRole.ReadDurationOverTargetCount
            [long]$expectedHardTotal =
                [long]$traceRole.ServiceGapOverHardLimitCount +
                [long]$traceRole.ReadDurationOverHardLimitCount
            [long]$eventHardTotal = @($traceEvents | Where-Object {
                  [double]$_.DurationMs -ge 100.0
                }).Count
            [bool]$eventRowsValid = @($traceEvents | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.Kind) -or
                [string]::IsNullOrWhiteSpace([string]$_.Phase) -or
                [string]::IsNullOrWhiteSpace([string]$_.Epoch) -or
                [double]$_.DurationMs -lt 75.0 -or
                [long]$_.StartedTimestampTicks -le 0 -or
                [long]$_.FinishedTimestampTicks -lt
                    [long]$_.StartedTimestampTicks
              }).Count -eq 0
            if ([int]$traceRole.ViolationEventCap -ne 64 -or
                [long]$traceRole.ViolationEventTotalCount -ne
                    $expectedTraceTotal -or
                [int]$traceRole.ViolationEventCount -ne $traceEvents.Count -or
                [long]$traceRole.ViolationEventOverflowCount -ne
                    ($expectedTraceTotal - $traceEvents.Count) -or
                $traceEvents.Count -gt 64 -or -not $eventRowsValid -or
                ([long]$traceRole.ViolationEventOverflowCount -eq 0 -and
                  $eventHardTotal -ne $expectedHardTotal)) {
              $allRoleTracesValid = $false
            }
          }
          $brokerViolationTraceValid = $allRoleTracesValid
          $brokerViolationTraceDetail = (
            'vehicle=' + [long]$barrierVehicle.ViolationEventCount + '/' +
            [long]$barrierVehicle.ViolationEventTotalCount + '/' +
            [long]$barrierVehicle.ViolationEventOverflowCount +
            ' ground=' + [long]$barrierGround.ViolationEventCount + '/' +
            [long]$barrierGround.ViolationEventTotalCount + '/' +
            [long]$barrierGround.ViolationEventOverflowCount)
        } else {
          $brokerViolationTraceDetail =
              'broker snapshot violation trace properties are absent'
        }
      } catch {
        $barrierCrossRoleFairnessDetail = $_.Exception.GetType().FullName +
            ': ' + $_.Exception.Message
        $brokerViolationTraceDetail = $barrierCrossRoleFairnessDetail
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_barrier_cross_role_fairness_exact') `
        -Passed $barrierCrossRoleFairnessValid `
        -Detail $barrierCrossRoleFairnessDetail
    Add-Check -Name ('selftest_' + $scenarioName +
        '_broker_violation_trace_consistent') `
        -Passed $brokerViolationTraceValid `
        -Detail $brokerViolationTraceDetail

    $paramDiagnosticPath = Join-Path $selfEvidence `
        'param_list_diagnostics_model.json'
    [bool]$paramDiagnosticValid = $false
    if (Test-Path -LiteralPath $paramDiagnosticPath -PathType Leaf) {
      $paramDiagnostic = Get-Content -Raw -LiteralPath $paramDiagnosticPath |
          ConvertFrom-Json
      $paramDiagnosticValid = (
        [int]$paramDiagnostic.schema_version -eq 1 -and
        $null -ne $paramDiagnostic.backlog_drain_gate -and
        $null -ne $paramDiagnostic.PSObject.Properties['baseline_pair_gate'] -and
        $null -ne $paramDiagnostic.baseline_setup -and
        $null -ne $paramDiagnostic.PSObject.Properties['pre_request_pair_gate'] -and
        $null -ne $paramDiagnostic.pre_request_vehicle_gate -and
        $null -ne $paramDiagnostic.pre_request_backlog_gate -and
        $null -ne $paramDiagnostic.official -and
        $null -ne $paramDiagnostic.official.stop_reason -and
        $null -ne $paramDiagnostic.post_cutoff -and
        $null -ne $paramDiagnostic.proxy_terminal -and
        $null -ne $paramDiagnostic.proxy_terminal.classification)
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_param_list_diagnostic_schema') -Passed $paramDiagnosticValid `
        -Detail 'Modeled diagnostic artifact must parse and expose backlog/official/post-cutoff/proxy sections.'

    $emptyParamDiagnosticPath = Join-Path $selfEvidence `
        'param_list_diagnostics_empty_model.json'
    [bool]$emptyParamDiagnosticValid = $false
    [string]$emptyParamDiagnosticDetail = 'artifact missing'
    if (Test-Path -LiteralPath $emptyParamDiagnosticPath -PathType Leaf) {
      [string]$emptyParamDiagnosticRaw = Get-Content -Raw -LiteralPath `
          $emptyParamDiagnosticPath
      try {
        $emptyParamDiagnostic = $emptyParamDiagnosticRaw | ConvertFrom-Json
        $officialEventsProperty = `
            $emptyParamDiagnostic.official.PSObject.Properties['events']
        $postEventsProperty = `
            $emptyParamDiagnostic.post_cutoff.PSObject.Properties['events']
        [int]$literalEmptyArrayCount = [regex]::Matches(
            $emptyParamDiagnosticRaw, '"events"\s*:\s*\[\]').Count
        $emptyParamDiagnosticValid = (
          $null -ne $officialEventsProperty -and
          $null -ne $postEventsProperty -and
          $officialEventsProperty.Value -is [System.Array] -and
          $postEventsProperty.Value -is [System.Array] -and
          @($officialEventsProperty.Value).Count -eq 0 -and
          @($postEventsProperty.Value).Count -eq 0 -and
          [int]$emptyParamDiagnostic.official.event_count -eq 0 -and
          [int]$emptyParamDiagnostic.post_cutoff.event_count -eq 0 -and
          $literalEmptyArrayCount -eq 2)
        $emptyParamDiagnosticDetail = ('literal_empty_arrays=' +
          $literalEmptyArrayCount + ' official_type=' +
          $officialEventsProperty.Value.GetType().FullName +
          ' post_type=' + $postEventsProperty.Value.GetType().FullName)
      } catch {
        $emptyParamDiagnosticDetail = $_.Exception.GetType().FullName +
            ': ' + $_.Exception.Message
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_param_list_diagnostic_nested_empty_arrays') `
        -Passed $emptyParamDiagnosticValid `
        -Detail $emptyParamDiagnosticDetail

    $prefilterModelPath = Join-Path $selfEvidence `
        'readiness_passive_prefilter_model.json'
    [bool]$prefilterModelValid = $false
    [string]$prefilterModelDetail = 'artifact missing'
    if (Test-Path -LiteralPath $prefilterModelPath -PathType Leaf) {
      [string]$prefilterModelRaw = Get-Content -Raw -LiteralPath `
          $prefilterModelPath
      try {
        $prefilterModel = $prefilterModelRaw | ConvertFrom-Json
        [string[]]$criticalBooleanNames = @(
          'candidate','sync_invalid','idle','capture_completed',
          'any_sync_invalid','run_ground','run_vehicle')
        [bool]$criticalBooleanTypes = $true
        foreach ($passiveCase in @($prefilterModel.passive_cases)) {
          foreach ($booleanName in @('candidate','sync_invalid','idle',
              'capture_completed')) {
            $booleanProperty = $passiveCase.PSObject.Properties[$booleanName]
            if ($null -eq $booleanProperty -or
                -not ($booleanProperty.Value -is [bool])) {
              $criticalBooleanTypes = $false
            }
          }
        }
        foreach ($booleanName in @('any_sync_invalid','run_ground',
            'run_vehicle')) {
          $booleanProperty = `
              $prefilterModel.post_plan.PSObject.Properties[$booleanName]
          if ($null -eq $booleanProperty -or
              -not ($booleanProperty.Value -is [bool])) {
            $criticalBooleanTypes = $false
          }
        }
        [int]$rawBooleanKeyCount = 0
        [int]$rawBooleanLiteralCount = 0
        foreach ($booleanName in $criticalBooleanNames) {
          $rawBooleanKeyCount += [regex]::Matches($prefilterModelRaw,
              ('"' + [regex]::Escape($booleanName) + '"\s*:')).Count
          $rawBooleanLiteralCount += [regex]::Matches($prefilterModelRaw,
              ('"' + [regex]::Escape($booleanName) +
               '"\s*:\s*(?:true|false)(?=\s*[,}])')).Count
        }
        $prefilterModelValid = (
          [int]$prefilterModel.schema_version -eq 1 -and
          @($prefilterModel.passive_cases).Count -ge 6 -and
          $criticalBooleanTypes -and
          $rawBooleanKeyCount -eq $rawBooleanLiteralCount)
        $prefilterModelDetail = ('bool_keys=' + $rawBooleanKeyCount +
          ' bool_literals=' + $rawBooleanLiteralCount +
          ' types=' + $criticalBooleanTypes)
      } catch {
        $prefilterModelDetail = $_.Exception.GetType().FullName + ': ' +
            $_.Exception.Message
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_prefilter_boolean_schema') -Passed $prefilterModelValid `
        -Detail $prefilterModelDetail

    $postQueryMatcherModelPath = Join-Path $selfEvidence `
        'readiness_post_query_matcher_model.json'
    [bool]$postQueryMatcherModelValid = $false
    [string]$postQueryMatcherModelDetail = 'missing'
    if (Test-Path -LiteralPath $postQueryMatcherModelPath -PathType Leaf) {
      try {
        [string]$postQueryMatcherModelRaw = [System.IO.File]::ReadAllText(
            $postQueryMatcherModelPath)
        $postQueryMatcherModel = $postQueryMatcherModelRaw |
            ConvertFrom-Json
        $postQueryCases = @($postQueryMatcherModel.cases |
          ForEach-Object {$_})
        [bool]$postQueryCasesValid = ($postQueryCases.Count -eq 6)
        foreach ($expectedPostQueryCase in @(
            [pscustomobject]@{name='A_partial_timeout';stage='A';
              hex='5643535441543120713D3133';count=12;start=500;raw=512;
              overflow=0;failure='timeout_or_partial'},
            [pscustomobject]@{name='B_partial_timeout';stage='B';
              hex='5643535441543220713D3134';count=12;start=800;raw=812;
              overflow=0;failure='timeout_or_partial'},
            [pscustomobject]@{name='A_overflow_timeout';stage='A';hex='';
              count=0;start=-1;raw=1000;overflow=1;
              failure='timeout_or_partial'},
            [pscustomobject]@{name='B_overflow_timeout';stage='B';hex='';
              count=0;start=-1;raw=1050;overflow=1;
              failure='timeout_or_partial'},
            [pscustomobject]@{name='A_complete_trailing_partial';stage='A';
              hex='41';count=1;start=1100;raw=1101;overflow=0;
              failure='post_query_matcher_dirty'},
            [pscustomobject]@{name='B_complete_trailing_partial';stage='B';
              hex='42';count=1;start=1200;raw=1201;overflow=0;
              failure='post_query_matcher_dirty'})) {
          $matchingPostQueryCases = @($postQueryCases | Where-Object {
              [string]$_.name -ceq $expectedPostQueryCase.name})
          if ($matchingPostQueryCases.Count -ne 1) {
            $postQueryCasesValid = $false
            continue
          }
          $postQueryCase = $matchingPostQueryCases[0]
          foreach ($snapshotName in @('post_query','transition_matcher',
              'latch_matcher','suppressed_matcher',
              'continuation_matcher')) {
            $snapshotProperty = `
                $postQueryCase.PSObject.Properties[$snapshotName]
            if ($null -eq $snapshotProperty) {
              $postQueryCasesValid = $false
              continue
            }
            $snapshotValue = $snapshotProperty.Value
            if ([long]$snapshotValue.pending_byte_count -ne
                  [long]$expectedPostQueryCase.count -or
                [string]$snapshotValue.pending_bytes_hex -cne
                  [string]$expectedPostQueryCase.hex -or
                [long]$snapshotValue.pending_start_offset -ne
                  [long]$expectedPostQueryCase.start -or
                [long]$snapshotValue.raw_bytes -ne
                  [long]$expectedPostQueryCase.raw -or
                [uint64]$snapshotValue.overflow_count -ne
                  [uint64]$expectedPostQueryCase.overflow) {
              $postQueryCasesValid = $false
            }
          }
          if ([string]$postQueryCase.stage -cne
                [string]$expectedPostQueryCase.stage -or
              [string]$postQueryCase.failure -cne
                [string]$expectedPostQueryCase.failure -or
              [long]$postQueryCase.pre_query.pending_byte_count -ne 0 -or
              [string]$postQueryCase.pre_query.pending_bytes_hex -cne '' -or
              [long]$postQueryCase.pre_query.pending_start_offset -ne -1 -or
              [uint64]$postQueryCase.pre_query.overflow_count -ne [uint64]0 -or
              -not ($postQueryCase.transition_valid -is [bool]) -or
              $postQueryCase.transition_valid -ne $false -or
              [long]$postQueryCase.suppressed_query_count -ne 0 -or
              -not ($postQueryCase.continuation_valid -is [bool]) -or
              $postQueryCase.continuation_valid -ne $true -or
              [uint64]$postQueryCase.continuation_write_delta -ne
                [uint64]0) {
            $postQueryCasesValid = $false
          }
        }
        [int]$rawTransitionValidCount = [regex]::Matches(
            $postQueryMatcherModelRaw,
            '"transition_valid"\s*:\s*false(?=\s*[,}])').Count
        [int]$rawContinuationValidCount = [regex]::Matches(
            $postQueryMatcherModelRaw,
            '"continuation_valid"\s*:\s*true(?=\s*[,}])').Count
        $postQueryMatcherModelValid = (
          [int]$postQueryMatcherModel.schema_version -eq 1 -and
          $postQueryCasesValid -and $rawTransitionValidCount -eq 6 -and
          $rawContinuationValidCount -eq 6 -and
          -not $postQueryMatcherModelRaw.Contains('{}'))
        $postQueryMatcherModelDetail = ('cases=' + $postQueryCases.Count +
          ' transition_false=' + $rawTransitionValidCount +
          ' continuation_true=' + $rawContinuationValidCount)
      } catch {
        $postQueryMatcherModelDetail = $_.Exception.GetType().FullName +
            ': ' + $_.Exception.Message
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_post_query_matcher_latch_exact') `
        -Passed $postQueryMatcherModelValid `
        -Detail $postQueryMatcherModelDetail

    $usbWakeModelPath = Join-Path $selfEvidence `
        'readiness_vehicle_B_usb_wake_model.json'
    [bool]$usbWakeModelValid = $false
    [string]$usbWakeModelDetail = 'missing'
    if (Test-Path -LiteralPath $usbWakeModelPath -PathType Leaf) {
      try {
        [string]$usbWakeModelRaw = [System.IO.File]::ReadAllText(
            $usbWakeModelPath)
        $usbWakeModel = $usbWakeModelRaw | ConvertFrom-Json
        $usbWakeCases = @($usbWakeModel.cases | ForEach-Object {$_})
        $expectedUsbWakeCases = @(
          @('R3_exact_97_byte_partial',$true,'eligible'),
          @('stall_249_999_ms',$false,'stall_below_threshold'),
          @('stall_250_ms',$true,'eligible'),
          @('remaining_599_999_ms',$false,'insufficient_deadline'),
          @('remaining_600_ms',$true,'eligible'),
          @('second_attempt',$false,'attempt_exhausted'),
          @('opt_out',$false,'not_opted_in'),
          @('ground_role',$false,'wrong_role'),
          @('missing_expected_q',$false,'missing_expected_q'),
          @('query_not_written',$false,'query_not_exact'),
          @('query_write_timed_out',$false,'query_not_exact'),
          @('report_already_complete',$false,'report_complete'),
          @('wrong_q_prefix',$false,'prefix_not_exact'),
          @('short_prefix',$false,'prefix_not_exact'),
          @('VCSTAT2_prefix',$false,'prefix_not_exact'),
          @('canonical_field_order_changed',$false,'prefix_not_exact'),
          @('nonprintable_byte',$false,'pending_not_printable'),
          @('preexisting_partial_matcher',$false,'pre_query_matcher_dirty'),
          @('overflow_delta',$false,'matcher_overflow_changed'),
          @('tagged_line_progress',$false,'tagged_line_progress'),
          @('raw_discontinuity',$false,'raw_not_contiguous'))
        [bool]$usbWakeCasesExact = ($usbWakeCases.Count -eq
            $expectedUsbWakeCases.Count -and
          @($usbWakeCases | Group-Object name | Where-Object {
            $_.Count -ne 1}).Count -eq 0)
        foreach ($expectedUsbWakeCase in $expectedUsbWakeCases) {
          $matchingUsbWakeCase = @($usbWakeCases | Where-Object {
              [string]$_.name -ceq [string]$expectedUsbWakeCase[0]})
          if ($matchingUsbWakeCase.Count -ne 1) {
            $usbWakeCasesExact = $false
            continue
          }
          $usbWakeCase = $matchingUsbWakeCase[0]
          if (-not ($usbWakeCase.expected_eligible -is [bool]) -or
              -not ($usbWakeCase.decision.eligible -is [bool]) -or
              [bool]$usbWakeCase.expected_eligible -ne
                [bool]$expectedUsbWakeCase[1] -or
              [bool]$usbWakeCase.decision.eligible -ne
                [bool]$expectedUsbWakeCase[1] -or
              [string]$usbWakeCase.expected_reason -cne
                [string]$expectedUsbWakeCase[2] -or
              [string]$usbWakeCase.decision.reason -cne
                [string]$expectedUsbWakeCase[2]) {
            $usbWakeCasesExact = $false
          }
        }
        $usbWakeR3Cases = @($usbWakeCases | Where-Object {
            [string]$_.name -ceq 'R3_exact_97_byte_partial'})
        [bool]$usbWakeR3Exact = ($usbWakeR3Cases.Count -eq 1 -and
          [long]$usbWakeR3Cases[0].decision.pending_byte_count -eq 97 -and
          [long]$usbWakeR3Cases[0].decision.start_raw_offset -eq 2472 -and
          [bool]$usbWakeR3Cases[0].decision.pending_printable -and
          [bool]$usbWakeR3Cases[0].decision.raw_contiguous -and
          [bool]$usbWakeR3Cases[0].decision.canonical_prefix_exact -and
          [double]$usbWakeR3Cases[0].decision.stall_ms -eq 250.0 -and
          [double]$usbWakeR3Cases[0].decision.remaining_ms -eq 600.0 -and
          [double]$usbWakeR3Cases[0].decision.write_plan.write_timeout_ms -eq
            100.0 -and
          [double]$usbWakeR3Cases[0].decision.write_plan.margin_ms -eq 500.0 -and
          -not [bool]$usbWakeR3Cases[0].decision.write_plan.base_stream_flush_allowed -and
          [string]$usbWakeR3Cases[0].decision.wake_byte_hex -ceq '0D' -and
          [string]$usbWakeR3Cases[0].decision.pending_sha256 -cmatch
            '^[0-9A-F]{64}$')
        $usbWakeModelValid = (
          [int]$usbWakeModel.schema_version -eq 1 -and
          [double]$usbWakeModel.stall_threshold_ms -eq 250.0 -and
          [double]$usbWakeModel.minimum_remaining_ms -eq 600.0 -and
          [double]$usbWakeModel.write_timeout_ms -eq 100.0 -and
          [double]$usbWakeModel.write_margin_ms -eq 500.0 -and
          [string]$usbWakeModel.wake_byte_hex -ceq '0D' -and
          [int]$usbWakeModel.max_attempts -eq 1 -and
          $usbWakeCasesExact -and $usbWakeR3Exact -and
          @($usbWakeCases | Where-Object {
            [bool]$_.decision.eligible}).Count -eq 3 -and
          @($usbWakeCases | Where-Object {
            -not [bool]$_.decision.eligible}).Count -eq 18)
        $usbWakeModelDetail = ('cases=' + $usbWakeCases.Count +
          ' eligible=' + @($usbWakeCases | Where-Object {
            [bool]$_.decision.eligible}).Count +
          ' R3_exact=' + $usbWakeR3Exact)
      } catch {
        $usbWakeModelDetail = $_.Exception.GetType().FullName + ': ' +
            $_.Exception.Message
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_vehicle_B_usb_wake_model_exact') `
        -Passed $usbWakeModelValid -Detail $usbWakeModelDetail

    $epochIntegrityModelPath = Join-Path $selfEvidence `
        'readiness_epoch_close_integrity_model.json'
    [bool]$epochIntegrityModelValid = $false
    [string]$epochIntegrityModelDetail = 'missing'
    if (Test-Path -LiteralPath $epochIntegrityModelPath -PathType Leaf) {
      try {
        [string]$epochIntegrityModelRaw = [System.IO.File]::ReadAllText(
            $epochIntegrityModelPath)
        $epochIntegrityModel = $epochIntegrityModelRaw | ConvertFrom-Json
        $epochIntegrityCases = @($epochIntegrityModel.cases |
          ForEach-Object {$_})
        [string[]]$requiredIntegrityCases = @('boot_boundary',
          'A_budget_no_query','window_incomplete','B_budget_no_query',
          'finally')
        [bool]$integrityCasesValid = (
          $epochIntegrityCases.Count -eq $requiredIntegrityCases.Count -and
          @(Compare-Object -ReferenceObject $requiredIntegrityCases `
            -DifferenceObject ([string[]]@($epochIntegrityCases |
              ForEach-Object {[string]$_.name}))).Count -eq 0)
        foreach ($integrityCase in $epochIntegrityCases) {
          [string]$expectedStage = if (
              [string]$integrityCase.name -ceq 'boot_boundary') {
            'boot_boundary/pump_to_idle'
          } else { 'A_window_B' }
          if (-not ($integrityCase.sync_invalid -is [bool]) -or
              $integrityCase.sync_invalid -ne $true -or
              -not ($integrityCase.epoch_integrity_valid -is [bool]) -or
              $integrityCase.epoch_integrity_valid -ne $false -or
              -not $integrityCase.ground_latch.latched -or
              [string]$integrityCase.ground_latch.role -cne 'ground' -or
              [string]$integrityCase.ground_latch.stage -cne $expectedStage -or
              [long]$integrityCase.vehicle_query_count -ne 0 -or
              [long]$integrityCase.request_write_count -ne 0 -or
              $integrityCase.post_plan.run_ground -ne $false -or
              $integrityCase.post_plan.run_vehicle -ne $false -or
              -not ($integrityCase.post_plan.run_ground -is [bool]) -or
              -not ($integrityCase.post_plan.run_vehicle -is [bool])) {
            $integrityCasesValid = $false
          }
        }
        [int]$rawSyncTrueCount = [regex]::Matches(
            $epochIntegrityModelRaw,
            '"sync_invalid"\s*:\s*true(?=\s*[,}])').Count
        $epochIntegrityModelValid = (
          [int]$epochIntegrityModel.schema_version -eq 1 -and
          $integrityCasesValid -and $rawSyncTrueCount -ge 5 -and
          -not $epochIntegrityModelRaw.Contains('{}'))
        $epochIntegrityModelDetail = ('cases=' +
          $epochIntegrityCases.Count + ' sync_true=' + $rawSyncTrueCount)
      } catch {
        $epochIntegrityModelDetail = $_.Exception.GetType().FullName +
            ': ' + $_.Exception.Message
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_epoch_close_integrity_fail_closed') `
        -Passed $epochIntegrityModelValid `
        -Detail $epochIntegrityModelDetail

    $epochModelPath = Join-Path $selfEvidence `
        'readiness_epoch_harvest_model.json'
    [bool]$epochModelValid = $false
    if (Test-Path -LiteralPath $epochModelPath -PathType Leaf) {
      $epochModel = Get-Content -Raw -LiteralPath $epochModelPath |
          ConvertFrom-Json
      $epochRows = @($epochModel.paths | ForEach-Object {$_})
      $epochNames = @($epochRows | ForEach-Object {[string]$_.path})
      [string[]]$requiredEpochNames = @('boot_boundary',
        'HB_noncandidate','passive_parser_reject','A_pre_dirty','A_timeout',
        'B_pre_dirty','B_timeout','assessment_invalid','finally')
      $epochStarts = @($epochRows | ForEach-Object {[long]$_.raw_start_offset})
      [bool]$epochOffsetsOrdered = $true
      for ($epochIndex = 1; $epochIndex -lt $epochStarts.Count;
          ++$epochIndex) {
        if ($epochStarts[$epochIndex] -le $epochStarts[$epochIndex - 1]) {
          $epochOffsetsOrdered = $false
        }
      }
      $epochModelValid = (
        $epochRows.Count -eq 9 -and
        @($epochNames | Sort-Object -Unique).Count -eq 9 -and
        @(Compare-Object -ReferenceObject $requiredEpochNames `
          -DifferenceObject ([string[]]$epochNames)).Count -eq 0 -and
        @($epochRows | Where-Object {
          [long]$_.destination_count_after_first -ne 1 -or
          [long]$_.destination_count_after_repeat -ne 1 -or
          [long]$_.source_event_count -ne 1 -or
          [long]$_.raw_end_offset -lt [long]$_.raw_start_offset
        }).Count -eq 0 -and
        [long]$epochModel.missing_count -eq 0 -and
        [long]$epochModel.duplicate_count -eq 0 -and
        [bool]$epochModel.offsets_ordered -and $epochOffsetsOrdered)
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_epoch_harvest_exact_paths') -Passed $epochModelValid `
        -Detail 'nine required epoch exit paths preserve one #22 each exactly once with unique ordered raw boundaries'

    $artifactPath = Join-Path $selfEvidence 'artifact_hashes.json'
    [bool]$artifactExists = Test-Path -LiteralPath $artifactPath -PathType Leaf
    Add-Check -Name ('selftest_' + $scenarioName + '_artifact_hashes_exists') `
        -Passed $artifactExists -Detail $artifactPath
    [bool]$artifactCoverage = $false
    if ($artifactExists) {
      $parsedArtifactRows = Get-Content -Raw -LiteralPath $artifactPath |
          ConvertFrom-Json
      $artifactRows = @($parsedArtifactRows | ForEach-Object {$_})
      $actualFiles = @(Get-ChildItem -LiteralPath $selfEvidence -File `
          -Recurse | Where-Object {$_.FullName -ne $artifactPath})
      $artifactCoverage = ($artifactRows.Count -eq $actualFiles.Count)
      foreach ($actualFile in $actualFiles) {
        [string]$relative = $actualFile.FullName.Substring(
            $selfEvidence.Length).TrimStart('\')
        $hashRow = @($artifactRows | Where-Object {$_.file -eq $relative})
        if ($hashRow.Count -ne 1 -or
            [long]($hashRow[0].size_bytes) -ne [long]$actualFile.Length -or
            [string]($hashRow[0].sha256) -ne
                (Get-FileHash -Algorithm SHA256 `
                    -LiteralPath $actualFile.FullName).Hash) {
          $artifactCoverage = $false
        }
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_artifact_hash_coverage') -Passed $artifactCoverage `
        -Detail 'Every pre-manifest self-test artifact must have exact size/SHA.'

    $liveProgressPath = Join-Path $selfEvidence 'live_progress.jsonl'
    [bool]$liveProgressValid = $false
    if (Test-Path -LiteralPath $liveProgressPath -PathType Leaf) {
      $records = @(Get-Content -LiteralPath $liveProgressPath |
          ForEach-Object {$_ | ConvertFrom-Json})
      $expectedEvents = @('runner_started',
        'power_off_confirmed_waiting_for_ports','ports_reappeared',
        'ports_opened','data_plane_readiness_started',
        'data_plane_readiness_progress','data_plane_readiness_window',
        'data_plane_readiness_result',
        'backlog_drain_started','backlog_drain_progress',
        'backlog_drain_progress','backlog_drain_result',
        'baseline_complete','pre_request_vehicle_complete',
        'request_sent','progress',
        'progress','list_complete','duplicate_guard_complete',
        'post_snapshots','footer_fsynced','final_status')
      $liveProgressValid = ($records.Count -eq $expectedEvents.Count)
      for ($recordIndex = 0; $recordIndex -lt $records.Count;
          ++$recordIndex) {
        if ($records[$recordIndex].event -ne $expectedEvents[$recordIndex]) {
          $liveProgressValid = $false
        }
        if ($recordIndex -gt 0 -and
            ([double]($records[$recordIndex].elapsed_s) -lt
              [double]($records[$recordIndex - 1].elapsed_s) -or
             [int]($records[$recordIndex].indexed) -lt
              [int]($records[$recordIndex - 1].indexed))) {
          $liveProgressValid = $false
        }
      }
    }
    Add-Check -Name ('selftest_' + $scenarioName +
        '_live_progress_order_monotonic') -Passed $liveProgressValid `
        -Detail 'Durable lifecycle record order and elapsed/index monotonicity.'

    if ($scenarioName -eq 'measured_fail') {
      $emptyVehiclePath = Join-Path $selfEvidence `
          'durable_empty_failure\vehicle_rx.raw.bin'
      $emptyGroundPath = Join-Path $selfEvidence `
          'durable_empty_failure\ground_rx.raw.bin'
      $emptyFooterPath = Join-Path $selfEvidence `
          'durable_empty_failure\capture_footer.json'
      [bool]$emptyFailurePresent = (
        (Test-Path -LiteralPath $emptyVehiclePath -PathType Leaf) -and
        (Test-Path -LiteralPath $emptyGroundPath -PathType Leaf) -and
        (Test-Path -LiteralPath $emptyFooterPath -PathType Leaf))
      if ($emptyFailurePresent) {
        $emptyFailurePresent = ((Get-Item -LiteralPath $emptyVehiclePath).Length -eq 0 -and
            (Get-Item -LiteralPath $emptyGroundPath).Length -eq 0)
      }
      Add-Check -Name 'selftest_measured_fail_empty_raw_footer' `
          -Passed $emptyFailurePresent `
          -Detail 'Measured FAIL retains durable empty raw files and footer.'
    }
    if ($scenarioName -eq 'power_off_timeout') {
      $timeoutDirectory = Join-Path $selfEvidence `
          'modeled_preopen_power_off_timeout'
      $timeoutVehicle = Join-Path $timeoutDirectory 'vehicle_rx.raw.bin'
      $timeoutGround = Join-Path $timeoutDirectory 'ground_rx.raw.bin'
      $timeoutFooterPath = Join-Path $timeoutDirectory 'capture_footer.json'
      $timeoutSummaryPath = Join-Path $timeoutDirectory 'summary.json'
      $timeoutManifestPath = Join-Path $timeoutDirectory `
          'artifact_hashes.json'
      $timeoutProgressPath = Join-Path $timeoutDirectory `
          'live_progress.jsonl'
      [bool]$timeoutEvidenceComplete = (
        (Test-Path -LiteralPath $timeoutVehicle -PathType Leaf) -and
        (Test-Path -LiteralPath $timeoutGround -PathType Leaf) -and
        (Test-Path -LiteralPath $timeoutFooterPath -PathType Leaf) -and
        (Test-Path -LiteralPath $timeoutSummaryPath -PathType Leaf) -and
        (Test-Path -LiteralPath $timeoutManifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $timeoutProgressPath -PathType Leaf))
      Add-Check -Name 'selftest_power_off_timeout_complete_evidence_set' `
          -Passed $timeoutEvidenceComplete `
          -Detail 'pre-open timeout must retain raw/footer/summary/manifest/live progress'
      if ($timeoutEvidenceComplete) {
        $timeoutFooter = Get-Content -Raw -LiteralPath $timeoutFooterPath |
            ConvertFrom-Json
        $timeoutSummary = Get-Content -Raw -LiteralPath $timeoutSummaryPath |
            ConvertFrom-Json
        [string]$emptySha = `
            'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        [bool]$timeoutClassification = (
          [string]$timeoutFooter.status -eq 'FAIL' -and
          [string]$timeoutSummary.status -eq 'FAIL' -and
          [long]$timeoutFooter.open_counts.vehicle -eq 0 -and
          [long]$timeoutFooter.open_counts.ground -eq 0 -and
          [long]$timeoutFooter.fixture_write_count -eq 0 -and
          [long]$timeoutSummary.serial_open_count -eq 0 -and
          [long]$timeoutSummary.request_write_count -eq 0 -and
          [long](Get-Item -LiteralPath $timeoutVehicle).Length -eq 0 -and
          [long](Get-Item -LiteralPath $timeoutGround).Length -eq 0 -and
          [string]$timeoutFooter.raw_capture.vehicle_sha256 -eq $emptySha -and
          [string]$timeoutFooter.raw_capture.ground_sha256 -eq $emptySha -and
          [bool]$timeoutFooter.raw_capture.streams_disposed_before_hash)
        Add-Check -Name 'selftest_power_off_timeout_fail_not_error' `
            -Passed $timeoutClassification `
            -Detail 'timeout is durable FAIL/1 with open0/write0/empty raw exact hashes'

        $timeoutRecords = @(Get-Content -LiteralPath $timeoutProgressPath |
            ForEach-Object {$_ | ConvertFrom-Json})
        $timeoutExpectedEvents = @('runner_started',
          'pre_power_identity_bound','error','footer_fsynced','final_status')
        [bool]$timeoutProgressValid = (
          $timeoutRecords.Count -eq $timeoutExpectedEvents.Count)
        for ($timeoutRecordIndex = 0;
            $timeoutRecordIndex -lt $timeoutRecords.Count;
            ++$timeoutRecordIndex) {
          if ($timeoutRecords[$timeoutRecordIndex].event -ne
              $timeoutExpectedEvents[$timeoutRecordIndex]) {
            $timeoutProgressValid = $false
          }
        }
        if ($timeoutRecords.Count -eq $timeoutExpectedEvents.Count) {
          $timeoutProgressValid = ($timeoutProgressValid -and
            [string]$timeoutRecords[2].status -eq 'FAIL' -and
            [string]$timeoutRecords[4].status -eq 'FAIL')
        }
        Add-Check -Name 'selftest_power_off_timeout_live_final_status' `
            -Passed $timeoutProgressValid `
            -Detail 'runner_started/pre_identity/error/footer_fsynced/final_status FAIL order'

        $timeoutManifest = Get-Content -Raw -LiteralPath $timeoutManifestPath |
            ConvertFrom-Json
        $timeoutRows = @($timeoutManifest.files | ForEach-Object {$_})
        $timeoutActual = @(Get-ChildItem -LiteralPath $timeoutDirectory -File |
            Where-Object {$_.FullName -ne $timeoutManifestPath})
        $timeoutRowNames = @($timeoutRows | ForEach-Object {[string]$_.file})
        $timeoutUniqueRowNames = @($timeoutRowNames | Sort-Object -Unique)
        $timeoutDiskNames = @($timeoutActual | ForEach-Object {$_.Name} |
            Sort-Object)
        $timeoutSortedRowNames = @($timeoutRowNames | Sort-Object)
        [bool]$timeoutCoverage = ($timeoutRows.Count -eq
            $timeoutActual.Count -and
            $timeoutUniqueRowNames.Count -eq $timeoutRows.Count -and
            (($timeoutSortedRowNames -join "`n") -ceq
              ($timeoutDiskNames -join "`n")))
        foreach ($timeoutFile in $timeoutActual) {
          $timeoutRow = @($timeoutRows | Where-Object {
              $_.file -eq $timeoutFile.Name})
          if ($timeoutRow.Count -ne 1 -or
              [long]$timeoutRow[0].size_bytes -ne [long]$timeoutFile.Length -or
              [string]$timeoutRow[0].sha256 -ne
                  (Get-FileHash -Algorithm SHA256 `
                    -LiteralPath $timeoutFile.FullName).Hash) {
            $timeoutCoverage = $false
          }
        }
        Add-Check -Name 'selftest_power_off_timeout_manifest_complete' `
            -Passed $timeoutCoverage `
            -Detail 'modeled timeout manifest has exact full pre-manifest coverage'
        Add-Check -Name 'selftest_power_off_timeout_no_footer_error' `
            -Passed (-not (Test-Path -LiteralPath (Join-Path `
              $timeoutDirectory 'capture_footer_error.json'))) `
            -Detail 'expected measured FAIL must not degrade to footer ERROR'
      }
    }
    if ($scenarioName -eq 'readiness_timeout') {
      $readinessDirectory = Join-Path $selfEvidence `
          'modeled_data_plane_readiness_timeout'
      $readinessFooterPath = Join-Path $readinessDirectory `
          'capture_footer.json'
      $readinessSummaryPath = Join-Path $readinessDirectory 'summary.json'
      $readinessManifestPath = Join-Path $readinessDirectory `
          'artifact_hashes.json'
      $readinessProgressPath = Join-Path $readinessDirectory `
          'live_progress.jsonl'
      [bool]$readinessEvidenceComplete = (
        (Test-Path -LiteralPath $readinessFooterPath -PathType Leaf) -and
        (Test-Path -LiteralPath $readinessSummaryPath -PathType Leaf) -and
        (Test-Path -LiteralPath $readinessManifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $readinessProgressPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $readinessDirectory `
          'post_ground.txt') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $readinessDirectory `
          'post_vehicle.txt') -PathType Leaf))
      Add-Check -Name 'selftest_readiness_timeout_complete_evidence_set' `
          -Passed $readinessEvidenceComplete `
          -Detail 'readiness timeout retains post diagnostics/footer/summary/manifest/live progress'
      if ($readinessEvidenceComplete) {
        $readinessFooter = Get-Content -Raw -LiteralPath `
            $readinessFooterPath | ConvertFrom-Json
        $readinessSummary = Get-Content -Raw -LiteralPath `
            $readinessSummaryPath | ConvertFrom-Json
        $readinessRecords = @(Get-Content -LiteralPath `
            $readinessProgressPath | ForEach-Object {$_ | ConvertFrom-Json})
        $readinessManifest = Get-Content -Raw -LiteralPath `
            $readinessManifestPath | ConvertFrom-Json
        $readinessActual = @(Get-ChildItem -LiteralPath $readinessDirectory `
            -File | Where-Object {$_.FullName -ne $readinessManifestPath})
        $readinessRows = @($readinessManifest.files | ForEach-Object {$_})
        [bool]$readinessCoverage = ($readinessRows.Count -eq
            $readinessActual.Count)
        foreach ($readinessFile in $readinessActual) {
          $readinessRow = @($readinessRows | Where-Object {
              $_.file -eq $readinessFile.Name})
          if ($readinessRow.Count -ne 1 -or
              [long]$readinessRow[0].size_bytes -ne
                [long]$readinessFile.Length -or
              [string]$readinessRow[0].sha256 -ne
                (Get-FileHash -Algorithm SHA256 `
                  -LiteralPath $readinessFile.FullName).Hash) {
            $readinessCoverage = $false
          }
        }
        $readinessFooterAssessment = $null
        $readinessFooterPostProperty =
            $readinessFooter.PSObject.Properties['post_diagnostics']
        if ($null -ne $readinessFooterPostProperty -and
            $null -ne $readinessFooterPostProperty.Value) {
          $readinessFooterAssessmentProperty =
              $readinessFooterPostProperty.Value.PSObject.Properties[
                'assessment']
          if ($null -ne $readinessFooterAssessmentProperty) {
            $readinessFooterAssessment =
                $readinessFooterAssessmentProperty.Value
          }
        }
        $readinessSummaryAssessment = $null
        $readinessSummaryAssessmentProperty =
            $readinessSummary.PSObject.Properties[
              'post_diagnostic_assessment']
        if ($null -ne $readinessSummaryAssessmentProperty) {
          $readinessSummaryAssessment =
              $readinessSummaryAssessmentProperty.Value
        }
        [string[]]$requestSuppressedAssessmentProperties = @(
          'status', 'evaluated', 'request_attempt_count',
          'fixture_write_count', 'failed_count', 'first_failed', 'checks')
        [bool]$readinessPostAssessmentNotRun = $false
        if ($null -ne $readinessFooterAssessment -and
            $null -ne $readinessSummaryAssessment -and
            @($requestSuppressedAssessmentProperties | Where-Object {
                $null -eq $readinessFooterAssessment.PSObject.Properties[$_]
              }).Count -eq 0 -and
            @($requestSuppressedAssessmentProperties | Where-Object {
                $null -eq $readinessSummaryAssessment.PSObject.Properties[$_]
              }).Count -eq 0) {
          $readinessPostAssessmentNotRun = (
            [string]$readinessFooterAssessment.status -eq
              'NOT_RUN_REQUEST_SUPPRESSED' -and
            -not [bool]$readinessFooterAssessment.evaluated -and
            [long]$readinessFooterAssessment.request_attempt_count -eq 0 -and
            [long]$readinessFooterAssessment.fixture_write_count -eq 0 -and
            [long]$readinessFooterAssessment.failed_count -eq 0 -and
            $null -eq $readinessFooterAssessment.first_failed -and
            @($readinessFooterAssessment.checks).Count -eq 0 -and
            [string]$readinessSummaryAssessment.status -eq
              'NOT_RUN_REQUEST_SUPPRESSED' -and
            -not [bool]$readinessSummaryAssessment.evaluated -and
            [long]$readinessSummaryAssessment.request_attempt_count -eq 0 -and
            [long]$readinessSummaryAssessment.fixture_write_count -eq 0 -and
            [long]$readinessSummaryAssessment.failed_count -eq 0 -and
            $null -eq $readinessSummaryAssessment.first_failed -and
            @($readinessSummaryAssessment.checks).Count -eq 0)
        }
        [bool]$readinessHasNoImpossiblePostFailure = (
          -not ((@($readinessFooter.errors) -join "`n") -match
            'post diagnostic contract failed') -and
          -not ((@($readinessSummary.errors) -join "`n") -match
            'post diagnostic contract failed'))
        [bool]$readinessClassification = (
          [string]$readinessFooter.status -eq 'FAIL' -and
          [bool]$readinessFooter.completed -and
          [long]$readinessFooter.open_counts.vehicle -eq 1 -and
          [long]$readinessFooter.open_counts.ground -eq 1 -and
          [long]$readinessFooter.fixture_write_count -eq 0 -and
          [string]$readinessSummary.status -eq 'FAIL' -and
          [long]$readinessSummary.exit_code -eq 1 -and
          [long]$readinessSummary.request_write_count -eq 0 -and
          [string]$readinessSummary.post_ground_status -eq 'COMPLETE' -and
          [string]$readinessSummary.post_vehicle_status -eq 'COMPLETE' -and
          $readinessPostAssessmentNotRun -and
          $readinessHasNoImpossiblePostFailure -and
          $readinessRecords[-1].event -eq 'final_status' -and
          [string]$readinessRecords[-1].status -eq 'FAIL' -and
          $readinessCoverage)
        Add-Check -Name 'selftest_readiness_timeout_fail1_no_request' `
            -Passed $readinessClassification `
            -Detail 'readiness timeout is setup-invalid FAIL/1, open1/1, write0, post diagnostics only, NOT_RUN_REQUEST_SUPPRESSED in footer/summary, exact manifest'
      }
    }
    if ($scenarioName -eq 'readiness_sync_invalid') {
      $syncDirectory = Join-Path $selfEvidence `
          'modeled_data_plane_readiness_sync_invalid'
      $syncFooterPath = Join-Path $syncDirectory 'capture_footer.json'
      $syncSummaryPath = Join-Path $syncDirectory 'summary.json'
      $syncManifestPath = Join-Path $syncDirectory 'artifact_hashes.json'
      $syncProgressPath = Join-Path $syncDirectory 'live_progress.jsonl'
      $syncContinuationPath = Join-Path $syncDirectory `
          'sync_invalid_continuation.json'
      $syncReadinessPath = Join-Path $syncDirectory `
          'data_plane_readiness.json'
      [bool]$syncEvidenceComplete = (
        (Test-Path -LiteralPath $syncFooterPath -PathType Leaf) -and
        (Test-Path -LiteralPath $syncSummaryPath -PathType Leaf) -and
        (Test-Path -LiteralPath $syncManifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $syncProgressPath -PathType Leaf) -and
        (Test-Path -LiteralPath $syncContinuationPath -PathType Leaf) -and
        (Test-Path -LiteralPath $syncReadinessPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $syncDirectory `
          'post_ground.txt') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $syncDirectory `
          'post_vehicle.txt') -PathType Leaf))
      Add-Check -Name 'selftest_readiness_sync_invalid_evidence_set' `
          -Passed $syncEvidenceComplete `
          -Detail 'sync-invalid FAIL retains footer/summary/progress/continuation/manifest and both empty post files'
      if ($syncEvidenceComplete) {
        $syncFooter = Get-Content -Raw -LiteralPath $syncFooterPath |
            ConvertFrom-Json
        $syncSummary = Get-Content -Raw -LiteralPath $syncSummaryPath |
            ConvertFrom-Json
        $syncContinuation = Get-Content -Raw -LiteralPath `
            $syncContinuationPath | ConvertFrom-Json
        $syncReadiness = Get-Content -Raw -LiteralPath `
            $syncReadinessPath | ConvertFrom-Json
        $syncRecords = @(Get-Content -LiteralPath $syncProgressPath |
            ForEach-Object {$_ | ConvertFrom-Json})
        $syncManifest = Get-Content -Raw -LiteralPath $syncManifestPath |
            ConvertFrom-Json
        $syncRows = @($syncManifest.files | ForEach-Object {$_})
        $syncActual = @(Get-ChildItem -LiteralPath $syncDirectory -File |
            Where-Object {$_.FullName -ne $syncManifestPath})
        [bool]$syncCoverage = ($syncRows.Count -eq $syncActual.Count -and
          @($syncRows | Group-Object file | Where-Object {
            $_.Count -ne 1}).Count -eq 0)
        foreach ($syncFile in $syncActual) {
          $syncRow = @($syncRows | Where-Object {
              $_.file -eq $syncFile.Name})
          if ($syncRow.Count -ne 1 -or
              [long]$syncRow[0].size_bytes -ne [long]$syncFile.Length -or
              [string]$syncRow[0].sha256 -ne
                (Get-FileHash -Algorithm SHA256 `
                  -LiteralPath $syncFile.FullName).Hash) {
            $syncCoverage = $false
          }
        }
        $syncGroundPost = Get-Item -LiteralPath (Join-Path $syncDirectory `
            'post_ground.txt')
        $syncVehiclePost = Get-Item -LiteralPath (Join-Path $syncDirectory `
            'post_vehicle.txt')
        [string]$expectedSuppressedText = `
            "NOT_RUN_SYNC_INVALID query_count=0 query_attempt_count=0 reason=SYNC_INVALID`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [byte[]]$expectedSuppressedBytes = `
            $utf8NoBom.GetBytes($expectedSuppressedText)
        $expectedSuppressedAlgorithm = `
            [System.Security.Cryptography.SHA256]::Create()
        try {
          [string]$expectedSuppressedSha256 = ([BitConverter]::ToString(
              $expectedSuppressedAlgorithm.ComputeHash(
                $expectedSuppressedBytes))).Replace('-', '')
        } finally {
          $expectedSuppressedAlgorithm.Dispose()
        }
        [string]$syncGroundPostText = [System.IO.File]::ReadAllText(
            $syncGroundPost.FullName, $utf8NoBom)
        [string]$syncVehiclePostText = [System.IO.File]::ReadAllText(
            $syncVehiclePost.FullName, $utf8NoBom)
        [bool]$syncBooleanTypes = $true
        foreach ($booleanSpec in @(
            @($syncFooter,'completed'),
            @($syncReadiness,'valid'),
            @($syncReadiness,'timed_out'),
            @($syncReadiness,'sync_invalid'),
            @($syncReadiness.ground_sync_invalid,'latched'),
            @($syncReadiness.vehicle_sync_invalid,'latched'),
            @($syncContinuation,'valid'))) {
          $booleanOwner = $booleanSpec[0]
          [string]$booleanName = [string]$booleanSpec[1]
          $booleanProperty = $booleanOwner.PSObject.Properties[$booleanName]
          if ($null -eq $booleanProperty -or
              -not ($booleanProperty.Value -is [bool])) {
            $syncBooleanTypes = $false
          }
        }
        [string]$syncBooleanRaw =
            (Get-Content -Raw -LiteralPath $syncFooterPath) + "`n" +
            (Get-Content -Raw -LiteralPath $syncReadinessPath) + "`n" +
            (Get-Content -Raw -LiteralPath $syncContinuationPath)
        [int]$syncBooleanKeyCount = 0
        [int]$syncBooleanLiteralCount = 0
        foreach ($booleanName in @('completed','valid','timed_out',
            'sync_invalid','latched')) {
          $syncBooleanKeyCount += [regex]::Matches($syncBooleanRaw,
              ('"' + $booleanName + '"\s*:')).Count
          $syncBooleanLiteralCount += [regex]::Matches($syncBooleanRaw,
              ('"' + $booleanName +
               '"\s*:\s*(?:true|false)(?=\s*[,}])')).Count
        }
        [bool]$syncClassification = (
          [string]$syncFooter.status -eq 'FAIL' -and
          $syncFooter.completed -eq $true -and
          [long]$syncFooter.open_counts.vehicle -eq 1 -and
          [long]$syncFooter.open_counts.ground -eq 1 -and
          [long]$syncFooter.fixture_write_count -eq 0 -and
          [string]$syncFooter.snapshots.post_ground -eq
            'NOT_RUN_SYNC_INVALID' -and
          [string]$syncFooter.snapshots.post_vehicle -eq
            'NOT_RUN_SYNC_INVALID' -and
          [string]$syncSummary.status -eq 'FAIL' -and
          [long]$syncSummary.exit_code -eq 1 -and
          [long]$syncSummary.request_write_count -eq 0 -and
          [long]$syncSummary.post_ground_query_count -eq 0 -and
          [long]$syncSummary.post_vehicle_query_count -eq 0 -and
          [string]$syncSummary.post_ground_status -eq
            'NOT_RUN_SYNC_INVALID' -and
          [string]$syncSummary.post_vehicle_status -eq
            'NOT_RUN_SYNC_INVALID' -and
          $syncGroundPostText -ceq $expectedSuppressedText -and
          $syncVehiclePostText -ceq $expectedSuppressedText -and
          [long]$syncGroundPost.Length -eq
            [long]$expectedSuppressedBytes.Length -and
          [long]$syncVehiclePost.Length -eq
            [long]$expectedSuppressedBytes.Length -and
          (Get-FileHash -Algorithm SHA256 -LiteralPath `
            $syncGroundPost.FullName).Hash -ceq $expectedSuppressedSha256 -and
          (Get-FileHash -Algorithm SHA256 -LiteralPath `
            $syncVehiclePost.FullName).Hash -ceq $expectedSuppressedSha256 -and
          $syncContinuation.valid -eq $true -and
          [long]$syncContinuation.diagnostic_write_count_delta -eq 0 -and
          $syncBooleanTypes -and
          $syncBooleanKeyCount -eq $syncBooleanLiteralCount -and
          @($syncRecords | Where-Object {
            $_.event -eq 'post_snapshots_suppressed_sync_invalid'
          }).Count -eq 1 -and
          $syncRecords[-1].event -eq 'final_status' -and
          [string]$syncRecords[-1].status -eq 'FAIL' -and
          $syncCoverage)
        Add-Check -Name 'selftest_readiness_sync_invalid_fail1_suppressed' `
            -Passed $syncClassification `
            -Detail 'sync-invalid is durable FAIL/1 open1/1 write0; both post queries suppressed, continuation pump write0, exact manifest'
      }
    }
    if ($scenarioName -eq 'postclose_error') {
      Add-Check -Name 'selftest_postclose_error_artifact' `
          -Passed (Test-Path -LiteralPath (Join-Path $selfEvidence `
              'postclose_finalization_error.json') -PathType Leaf) `
          -Detail 'Modeled post-close ERROR retains explicit durable artifact.'
      $finalizationRegressionPath = Join-Path $selfEvidence `
          'finalization_primary_error_regression.json'
      [bool]$finalizationRegressionExists = Test-Path -LiteralPath `
          $finalizationRegressionPath -PathType Leaf
      Add-Check -Name 'selftest_r5c_finalization_regression_artifact_exists' `
          -Passed $finalizationRegressionExists `
          -Detail $finalizationRegressionPath
      [bool]$finalizationRegressionValid = $false
      [string]$finalizationRegressionDetail = 'missing'
      if ($finalizationRegressionExists -and $null -ne $selfSummary) {
        try {
          $finalizationRegression = Get-Content -Raw `
              -LiteralPath $finalizationRegressionPath | ConvertFrom-Json
          $finalizationCase = @($selfSummary.cases | Where-Object {
              [string]$_.name -ceq
                  'post_ground_closed_then_shutdown_failure_preserves_primary'
            })
          [string]$regressionJson = $finalizationRegression |
              ConvertTo-Json -Depth 24 -Compress
          $finalizationRegressionValid = (
            [bool]$finalizationRegression.passed -and
            [bool]$finalizationRegression.backlog_projection_helper_present -and
            [bool]$finalizationRegression.failure_resolution_helper_present -and
            [bool]$finalizationRegression.raw_fallback_helper_present -and
            [bool]$finalizationRegression.pump_fallback_helper_present -and
            $finalizationCase.Count -eq 1 -and
            [bool]$finalizationCase[0].passed -and
            [string]$finalizationRegression.summary.status -ceq 'ERROR' -and
            [int]$finalizationRegression.summary.exit_code -eq 2 -and
            [string]$finalizationRegression.summary.failure -ceq
                [string]$finalizationRegression.primary_failure -and
            @($finalizationRegression.summary.errors).Count -eq 2 -and
            [string]$finalizationRegression.summary.errors[0] -ceq
                [string]$finalizationRegression.primary_failure -and
            [string]$finalizationRegression.summary.errors[1] -ceq
                [string]$finalizationRegression.finalization_failure -and
            [int]$finalizationRegression.summary.fixture.attempt_count -eq 1 -and
            [int]$finalizationRegression.summary.fixture.write_count -eq 1 -and
            -not [bool]$finalizationRegression.summary.fixture.write_uncertain -and
            [string]$finalizationRegression.summary.fixture.write_disposition -ceq
                'ACKNOWLEDGED_EXACTLY_ONCE' -and
            [bool]$finalizationRegression.pre_try_backlog_projection.not_run -and
            [bool]$finalizationRegression.completed_backlog_projection.valid -and
            -not [bool]$finalizationRegression.summary.raw_capture.seal_valid -and
            [long]$finalizationRegression.summary.raw_capture.vehicle_bytes -eq
                35948 -and
            [long]$finalizationRegression.summary.raw_capture.ground_bytes -eq
                69665 -and
            $null -eq $finalizationRegression.summary.raw_capture.vehicle_sha256 -and
            $null -eq $finalizationRegression.summary.raw_capture.ground_sha256 -and
            -not [bool]$finalizationRegression.summary.raw_capture.streams_disposed_before_hash -and
            -not [bool]$finalizationRegression.summary.pump_fairness.valid -and
            -not [bool]$finalizationRegression.summary.pump_fairness.measurement_complete -and
            $regressionJson -notmatch
                'backlogDrainEvidence|not been set|uninitialized')
          $finalizationRegressionDetail =
              'status=' + [string]$finalizationRegression.summary.status +
              ' write_count=' +
                [string]$finalizationRegression.summary.fixture.write_count +
              ' raw=' +
                [string]$finalizationRegression.summary.raw_capture.vehicle_bytes +
              '/' +
                [string]$finalizationRegression.summary.raw_capture.ground_bytes
        } catch {
          $finalizationRegressionDetail = $_.Exception.GetType().FullName +
              ': ' + $_.Exception.Message
        }
      }
      Add-Check -Name `
          'selftest_r5c_primary_survives_broken_pipe_and_summary_serializes' `
          -Passed $finalizationRegressionValid `
          -Detail $finalizationRegressionDetail
    }
    $childRuns.Add([pscustomobject][ordered]@{
      scenario=$scenarioName;argument=$scenarioArgument
      exit_code=$scenarioExit;expected_exit_code=$expectedExit
      status=if($null -ne $selfSummary){$selfSummary.status}else{$null}
      evidence_directory=$selfEvidence
      runner_sha256_before=$runnerChildPreSha
      runner_sha256_after=$runnerChildPostSha
      runner_size_before=$runnerChildPreSize
      runner_size_after=$runnerChildPostSize
      runner_source_exact=$runnerChildSourceExact
      checker_sha256_before=$checkerChildPreSha
      checker_sha256_after=$checkerChildPostSha
      checker_size_before=$checkerChildPreSize
      checker_size_after=$checkerChildPostSize
      checker_source_exact=$checkerChildSourceExact
    })
    $sourceBindingChildRows.Add([pscustomobject][ordered]@{
      scenario=$scenarioName
      runner_sha256_before=$runnerChildPreSha
      runner_sha256_after=$runnerChildPostSha
      runner_size_before=$runnerChildPreSize
      runner_size_after=$runnerChildPostSize
      runner_exact=$runnerChildSourceExact
      checker_sha256_before=$checkerChildPreSha
      checker_sha256_after=$checkerChildPostSha
      checker_size_before=$checkerChildPreSize
      checker_size_after=$checkerChildPostSize
      checker_exact=$checkerChildSourceExact
    })
  }
  $childExitCode = @($childRuns | Where-Object {
      $_.exit_code -ne $_.expected_exit_code }).Count
}

Write-TextDurable -Path (Join-Path $EvidenceDirectory 'stdout.txt') `
    -Text $childStdout
Write-TextDurable -Path (Join-Path $EvidenceDirectory 'stderr.txt') `
    -Text $childStderr

[string]$checkerFinalSha256 = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $checkerPath).Hash
[long]$checkerFinalSize = (Get-Item -LiteralPath $checkerPath).Length
[string]$runnerFinalSha256 = ''
[long]$runnerFinalSize = 0
if ($runnerExists) {
  $runnerFinalSha256 = (Get-FileHash -Algorithm SHA256 `
      -LiteralPath $RunnerPath).Hash
  $runnerFinalSize = (Get-Item -LiteralPath $RunnerPath).Length
}
[bool]$checkerStartEndExact = ($checkerFinalSha256 -ceq $checkerSha256 -and
    $checkerFinalSize -eq $checkerInitialSize)
[bool]$runnerStartEndExact = ($runnerExists -and
    $runnerFinalSha256 -ceq $runnerInitialSha256 -and
    $runnerFinalSize -eq $runnerInitialSize)
[int]$sourceBindingChildMismatchCount = @($sourceBindingChildRows |
    Where-Object {-not $_.runner_exact -or -not $_.checker_exact}).Count
[bool]$sourceBindingsHeldBeforeSummary = (
    $null -ne $checkerBoundStream -and $checkerBoundStream.CanRead -and
    $null -ne $runnerBoundStream -and $runnerBoundStream.CanRead)
Add-Check -Name 'checker_source_bound_start_end_exact' `
    -Passed $checkerStartEndExact `
    -Detail ('start=' + $checkerSha256 + ' final=' + $checkerFinalSha256 +
      ' size=' + $checkerFinalSize)
Add-Check -Name 'runner_source_bound_start_end_exact' `
    -Passed $runnerStartEndExact `
    -Detail ('start=' + $runnerInitialSha256 + ' final=' +
      $runnerFinalSha256 + ' size=' + $runnerFinalSize)
Add-Check -Name 'source_binding_child_pre_post_mismatch_zero' `
    -Passed ($sourceBindingChildMismatchCount -eq 0) `
    -Detail ('mismatch_count=' + $sourceBindingChildMismatchCount)
Add-Check -Name 'source_bindings_held_before_summary' `
    -Passed $sourceBindingsHeldBeforeSummary `
    -Detail 'Both FileShare.Read source handles remain open after every child and before summary/seal.'
[string]$checkerBoundCopyPath = Join-Path $EvidenceDirectory `
    'bound_checker_source.ps1'
[string]$runnerBoundCopyPath = Join-Path $EvidenceDirectory `
    'bound_runner_source.ps1'
[string]$checkerBoundCopySha = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $checkerBoundCopyPath).Hash
[string]$runnerBoundCopySha = if ($runnerExists) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $runnerBoundCopyPath).Hash
} else { '' }
Add-Check -Name 'bound_source_copies_exact' `
    -Passed ($checkerBoundCopySha -ceq $checkerSha256 -and
      $runnerBoundCopySha -ceq $runnerInitialSha256) `
    -Detail ('checker_copy=' + $checkerBoundCopySha +
      ' runner_copy=' + $runnerBoundCopySha)
$sourceBinding = [ordered]@{
  schema_version=2
  binding='FileStream FileMode.Open FileAccess.Read FileShare.Read'
  checker=[ordered]@{
    path=$checkerPath
    requested_full_path=[System.IO.Path]::GetFullPath($checkerPath)
    final_handle_path=$checkerFinalHandlePath
    final_handle_path_exact=$true
    reparse_components_checked_before_and_after_open=$true
    bound_copy='bound_checker_source.ps1'
    size_bytes=$checkerInitialSize
    sha256=$checkerSha256
    disk_start_sha256=$checkerDiskStartSha
    disk_final_sha256=$checkerFinalSha256
    start_end_exact=$checkerStartEndExact
    write_open_denied=$checkerWriteOpenDenied
    ast_error_count=@($checkerParseErrors).Count
  }
  runner=[ordered]@{
    path=$RunnerPath
    requested_full_path=if($runnerExists){
      [System.IO.Path]::GetFullPath($RunnerPath)
    }else{$null}
    final_handle_path=if($runnerExists){$runnerFinalHandlePath}else{$null}
    final_handle_path_exact=$runnerExists
    reparse_components_checked_before_and_after_open=$runnerExists
    bound_copy=if($runnerExists){'bound_runner_source.ps1'}else{$null}
    size_bytes=if($runnerExists){$runnerInitialSize}else{$null}
    sha256=if($runnerExists){$runnerInitialSha256}else{$null}
    disk_start_sha256=if($runnerExists){$runnerDiskStartSha}else{$null}
    disk_final_sha256=if($runnerExists){$runnerFinalSha256}else{$null}
    start_end_exact=$runnerStartEndExact
    write_open_denied=$runnerWriteOpenDenied
    ast_error_count=if($runnerExists){@($parseErrors).Count}else{$null}
  }
  child_pre_post_mismatch_count=$sourceBindingChildMismatchCount
  runner_child_process_start_count=$runnerChildProcessStartCount
  reparse_probe_checker_process_start_count=
    $sourcePathProbeCheckerProcessStartCount
  reparse_probe=$sourcePathReparseProbe
  child_runs=$sourceBindingChildRows.ToArray()
  source_handles_held_before_summary=$sourceBindingsHeldBeforeSummary
  unbound_to_bound_model=$sourceBindingModel
}
$sourceBindingPath = Join-Path $EvidenceDirectory 'source_binding.json'
Write-JsonDurable -Path $sourceBindingPath -Value $sourceBinding
[string]$sourceBindingSha256 = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $sourceBindingPath).Hash

$status = if ($failures.Count -eq 0) { 'GREEN' } else { 'RED' }
$summary = [ordered]@{
  schema_version = 2
  contract_id = 'HIL-DUAL-DIAG-PARAM-LIST-RUNNER-CONTRACT-001'
  status = $status
  started_utc = $startedUtc
  completed_utc = [DateTime]::UtcNow.ToString('o')
  repo = $repo
  checker_path = $checkerPath
  checker_sha256 = $checkerSha256
  runner_path = $RunnerPath
  runner_exists = $runnerExists
  runner_sha256 = if ($runnerExists) {$runnerInitialSha256} else {$null}
  source_binding_sha256 = $sourceBindingSha256
  source_binding = $sourceBinding
  runner_child_process_start_count = $runnerChildProcessStartCount
  source_path_reparse_probe = $sourcePathReparseProbe
  no_com_or_upload_scope = $true
  legacy_tools_audited_nogo = $legacyTools
  child_exit_mismatch_count = $childExitCode
  child_runs = if ($runnerExists) {$childRuns.ToArray()} else {@()}
  checks = $checks.ToArray()
  failure_count = $failures.Count
  failures = $failures.ToArray()
}
Write-JsonDurable -Path (Join-Path $EvidenceDirectory 'summary.json') `
    -Value $summary

$artifactRows = New-Object 'System.Collections.Generic.List[object]'
$rootArtifactManifestPath = Join-Path $EvidenceDirectory `
    'artifact_hashes.json'
foreach ($file in @(Get-ChildItem -LiteralPath $EvidenceDirectory -File `
    -Recurse | Where-Object {
      $_.FullName -ne $rootArtifactManifestPath
    } | Sort-Object FullName)) {
  [string]$relative = $file.FullName.Substring(
      $EvidenceDirectory.Length).TrimStart('\')
  $artifactRows.Add([pscustomobject][ordered]@{
        file = $relative
        size_bytes = [long]$file.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
      })
}
Write-JsonDurable -Path (Join-Path $EvidenceDirectory 'artifact_hashes.json') `
    -Value ([ordered]@{
      schema_version=2
      coverage='all regular evidence files before manifest/seal'
      covered_file_count=$artifactRows.Count
      files=$artifactRows.ToArray()
    })
$artifactManifestPath = $rootArtifactManifestPath
$summaryPath = Join-Path $EvidenceDirectory 'summary.json'
[bool]$checkerWriteOpenDeniedAtSeal = Test-WriteOpenDeniedByBinding `
    -Path $checkerPath
[bool]$runnerWriteOpenDeniedAtSeal = if ($runnerExists) {
  Test-WriteOpenDeniedByBinding -Path $RunnerPath
} else { $false }
$seal = [ordered]@{
  schema_version=1
  contract_id='HIL-DUAL-DIAG-PARAM-LIST-RUNNER-CONTRACT-001'
  status=$status
  checker_sha256=$checkerSha256
  runner_sha256=if($runnerExists){$runnerInitialSha256}else{$null}
  source_binding_sha256=$sourceBindingSha256
  source_bindings_held_at_seal=(
    $null -ne $checkerBoundStream -and $checkerBoundStream.CanRead -and
    $null -ne $runnerBoundStream -and $runnerBoundStream.CanRead)
  checker_write_open_denied_at_seal=$checkerWriteOpenDeniedAtSeal
  runner_write_open_denied_at_seal=$runnerWriteOpenDeniedAtSeal
  checker_final_handle_path=$checkerFinalHandlePath
  checker_final_handle_path_exact=$true
  runner_final_handle_path=if($runnerExists){$runnerFinalHandlePath}else{$null}
  runner_final_handle_path_exact=$runnerExists
  reparse_components_checked_before_and_after_open=$runnerExists
  summary_sha256=(Get-FileHash -Algorithm SHA256 `
      -LiteralPath $summaryPath).Hash
  artifact_hashes_sha256=(Get-FileHash -Algorithm SHA256 `
      -LiteralPath $artifactManifestPath).Hash
  artifact_count=$artifactRows.Count
  no_com_or_upload_scope=$true
  sealed_utc=[DateTime]::UtcNow.ToString('o')
}
$sealPath = Join-Path $EvidenceDirectory 'final_seal.json'
Write-JsonDurable -Path $sealPath -Value $seal
[string]$sealSha = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath $sealPath).Hash
Write-TextDurable -Path (Join-Path $EvidenceDirectory 'final_seal.sha256') `
    -Text ($sealSha + '  final_seal.json' + [Environment]::NewLine)

if ($null -ne $runnerBoundStream) {
  $runnerBoundStream.Dispose()
  $runnerBoundStream = $null
}
if ($null -ne $checkerBoundStream) {
  $checkerBoundStream.Dispose()
  $checkerBoundStream = $null
}

if ($status -eq 'GREEN') {
  Write-Host "GREEN dedicated #21/932 runner contract: $EvidenceDirectory seal=$sealSha"
  exit 0
}
[Console]::Error.WriteLine(
    "RED dedicated #21/932 runner contract: $EvidenceDirectory seal=$sealSha")
exit 1
