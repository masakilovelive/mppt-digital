[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
  $OutputDirectory = Join-Path $repo `
    "runs\contracts\HOST-SANITIZER-FULL-SUITE-RUNNER-001\$stamp"
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw "Refusing to overwrite evidence: $OutputDirectory"
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-FixtureFile([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

$runnerPath = Join-Path $repo 'tools\run_host_sanitizers.ps1'
$runner = [IO.File]::ReadAllText($runnerPath)
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
  $runnerPath, [ref]$null, [ref]$parseErrors)

$ctestInvocation = [regex]::Match(
  $runner,
  '(?ms)^\s*\$ctestRun\s*=\s*Invoke-NativeCapture\s+\$ctestPath\s+@\(\r?\n(?<arguments>.*?)^\s*\)\r?$'
)
$ctestArguments = if ($ctestInvocation.Success) {
  $ctestInvocation.Groups['arguments'].Value
} else {
  ''
}
$cleanupOffset = $runner.IndexOf(
  'Reset-FreshBuildDirectory $repo $buildDir',
  [StringComparison]::Ordinal
)
$configureOffset = $runner.IndexOf(
  '$configure = Invoke-NativeCapture',
  [StringComparison]::Ordinal
)

$fixture = Join-Path ([IO.Path]::GetTempPath()) `
  ("vc_lora_host_sanitizer_runner_" + [Guid]::NewGuid().ToString('N'))
$dynamic = [ordered]@{
  passed = $false
  child_exit_code = $null
  stale_build_removed = $false
  configure_observed_fresh_build = $false
  summary_status = $null
  registered_test_count = $null
  executed_test_count = $null
  ctest_full_call_has_filter = $null
  output = @()
  error = $null
}
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
  Copy-Item -LiteralPath $runnerPath -Destination `
    (Join-Path $fixture 'tools\run_host_sanitizers.ps1')
  $staleBuild = Join-Path $fixture 'build\host-sanitize'
  [void][IO.Directory]::CreateDirectory($staleBuild)
  Write-FixtureFile (Join-Path $staleBuild 'stale-marker.txt') "stale`n"

  $compilerStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ToolArgs)
if ($ToolArgs -contains '--version') {
  'clang version 22.1.8 (fixture)'
  exit 0
}
if ($ToolArgs -contains '-print-resource-dir') {
  Join-Path $PSScriptRoot 'lib\clang\22'
  exit 0
}
exit 2
'@
  $cmakeStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ToolArgs)
if ($ToolArgs.Count -gt 0 -and $ToolArgs[0] -eq '--build') {
  'fixture build PASS'
  exit 0
}
$buildIndex = [Array]::IndexOf($ToolArgs, '-B')
if ($buildIndex -lt 0 -or $buildIndex + 1 -ge $ToolArgs.Count) { exit 2 }
$buildDir = [string]$ToolArgs[$buildIndex + 1]
if (Test-Path -LiteralPath (Join-Path $buildDir 'stale-marker.txt')) { exit 3 }
[void][IO.Directory]::CreateDirectory($buildDir)
[IO.File]::WriteAllText(
  (Join-Path $PSScriptRoot 'configure-observed-fresh.txt'), "yes`n")
'fixture configure PASS'
exit 0
'@
  $ctestStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ToolArgs)
$names = @(
  'UT-BULK-NEG-WIRE-001',
  'UT-HS-TDD-COORD-001',
  'UT-HS-PHASE6-ADAPTER-001',
  'UT-CONTROL-V2-VCBN-DEMUX-001',
  'ST-001'
)
$calls = Join-Path $PSScriptRoot 'ctest-calls.txt'
[IO.File]::AppendAllText($calls, (($ToolArgs -join '|') + "`n"))
if ($ToolArgs -contains '--show-only=json-v1') {
  $tests = @()
  foreach ($name in $names) {
    $label = if ($name -eq 'ST-001') { 'phase5' } else { 'phase4' }
    $tests += [ordered]@{
      name = $name
      properties = @([ordered]@{ name = 'LABELS'; value = @($label) })
    }
  }
  [ordered]@{
    kind = 'ctestInfo'
    version = [ordered]@{ major = 1; minor = 0 }
    tests = $tests
  } | ConvertTo-Json -Depth 8 -Compress
  exit 0
}
foreach ($selection in @('-L', '-LE', '-R', '-E', '-I')) {
  if ($ToolArgs -contains $selection) { exit 4 }
}
$junitIndex = [Array]::IndexOf($ToolArgs, '--output-junit')
if ($junitIndex -lt 0 -or $junitIndex + 1 -ge $ToolArgs.Count) { exit 5 }
$junitPath = [string]$ToolArgs[$junitIndex + 1]
$cases = @($names | ForEach-Object {
  '<testcase name="' + $_ + '" classname="' + $_ + '" time="0.001" />'
}) -join ''
$xml = '<?xml version="1.0" encoding="UTF-8"?>' +
  '<testsuite name="fixture" tests="5" failures="0" disabled="0" ' +
  'errors="0" time="0.005">' + $cases + '</testsuite>'
$parent = Split-Path -Parent $junitPath
[void][IO.Directory]::CreateDirectory($parent)
[IO.File]::WriteAllText($junitPath, $xml)
'100% tests passed, 0 tests failed out of 5'
exit 0
'@
  $wrapper = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1" %*
exit /b %ERRORLEVEL%
'@
  foreach ($tool in @(
      [pscustomobject]@{ name = 'fake_compiler'; body = $compilerStub },
      [pscustomobject]@{ name = 'fake_cmake'; body = $cmakeStub },
      [pscustomobject]@{ name = 'fake_ctest'; body = $ctestStub }
    )) {
    Write-FixtureFile (Join-Path $fixture "$($tool.name).ps1") $tool.body
    Write-FixtureFile (Join-Path $fixture "$($tool.name).cmd") $wrapper
  }
  Write-FixtureFile (Join-Path $fixture 'fake_ninja.cmd') `
    "@echo off`r`nexit /b 0`r`n"
  Write-FixtureFile (Join-Path $fixture `
      'libclang_rt.asan_dynamic-x86_64.dll') ''

  $childPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $childOutput = @(& $childPowerShell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $fixture 'tools\run_host_sanitizers.ps1') `
    -CMake (Join-Path $fixture 'fake_cmake.cmd') `
    -CTest (Join-Path $fixture 'fake_ctest.cmd') `
    -Ninja (Join-Path $fixture 'fake_ninja.cmd') `
    -Compiler (Join-Path $fixture 'fake_compiler.cmd') 2>&1 |
      ForEach-Object { $_.ToString() })
  $dynamic.child_exit_code = $LASTEXITCODE
  $dynamic.output = $childOutput
  $dynamic.stale_build_removed = -not (Test-Path -LiteralPath `
    (Join-Path $staleBuild 'stale-marker.txt'))
  $dynamic.configure_observed_fresh_build = Test-Path -LiteralPath `
    (Join-Path $fixture 'configure-observed-fresh.txt')

  $fixtureSummaryPath = Join-Path $fixture `
    'runs\host_full_sanitizer_summary.json'
  if (Test-Path -LiteralPath $fixtureSummaryPath) {
    $fixtureSummary = Get-Content -LiteralPath $fixtureSummaryPath -Raw |
      ConvertFrom-Json
    $dynamic.summary_status = [string]$fixtureSummary.status
    $dynamic.registered_test_count = `
      [int]$fixtureSummary.coverage.registered_test_count
    $dynamic.executed_test_count = `
      [int]$fixtureSummary.coverage.executed_test_count
  }
  $callsPath = Join-Path $fixture 'ctest-calls.txt'
  if (Test-Path -LiteralPath $callsPath) {
    $fullCall = @(Get-Content -LiteralPath $callsPath |
      Where-Object { $_ -notmatch '--show-only=json-v1' } |
      Select-Object -Last 1)
    $dynamic.ctest_full_call_has_filter = [bool]($fullCall -match
      '(^|\|)-(L|LE|R|E|I)(\||$)')
  }
  $dynamic.passed = ($dynamic.child_exit_code -eq 0 -and
    $dynamic.stale_build_removed -and
    $dynamic.configure_observed_fresh_build -and
    $dynamic.summary_status -eq 'PASS' -and
    $dynamic.registered_test_count -eq 5 -and
    $dynamic.executed_test_count -eq 5 -and
    $dynamic.ctest_full_call_has_filter -eq $false)
} catch {
  $dynamic.error = $_.Exception.Message
} finally {
  $expectedPrefix = [IO.Path]::GetTempPath()
  if ($fixture.StartsWith(
      $expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fixture) -match
        '^vc_lora_host_sanitizer_runner_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fixture)) {
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}

$checks = @(
  [pscustomobject][ordered]@{
    name = 'powershell_syntax_valid'
    valid = ($parseErrors.Count -eq 0)
  },
  [pscustomobject][ordered]@{
    name = 'full_suite_identity'
    valid = ($runner -match "suite\s*=\s*'host_full_sanitizers'")
  },
  [pscustomobject][ordered]@{
    name = 'full_suite_artifact_names'
    valid = ($runner -match "host_full_sanitizer_summary\.json" -and
      $runner -match "host_full_sanitizer_ctest\.log" -and
      $runner -match "host_full_sanitizer_junit\.xml")
  },
  [pscustomobject][ordered]@{
    name = 'fresh_build_reset_is_declared'
    valid = ($runner -match '(?s)function\s+Reset-FreshBuildDirectory.*?Remove-Item\s+-LiteralPath\s+\$BuildDirectory\s+-Recurse\s+-Force')
  },
  [pscustomobject][ordered]@{
    name = 'fresh_build_reset_precedes_configure'
    valid = ($cleanupOffset -ge 0 -and $configureOffset -gt $cleanupOffset)
  },
  [pscustomobject][ordered]@{
    name = 'fresh_build_reset_has_exact_path_guard'
    valid = ($runner -match '(?s)function\s+Reset-FreshBuildDirectory.*?GetFullPath.*?host-sanitize.*?OrdinalIgnoreCase.*?throw')
  },
  [pscustomobject][ordered]@{
    name = 'ctest_invocation_detected'
    valid = $ctestInvocation.Success
  },
  [pscustomobject][ordered]@{
    name = 'ctest_selection_has_no_filter'
    valid = ($ctestArguments -notmatch "(?m)'-(L|LE|R|E|I)'\s*,")
  },
  [pscustomobject][ordered]@{
    name = 'ctest_writes_junit'
    valid = ($ctestArguments -match
      '''--output-junit''\s*,\s*\$junitPath')
  },
  [pscustomobject][ordered]@{
    name = 'registry_is_enumerated_without_filter'
    valid = ($runner -match "'--show-only=json-v1'")
  },
  [pscustomobject][ordered]@{
    name = 'registry_and_junit_are_reconciled'
    valid = ($runner -match 'missing_registered_tests' -and
      $runner -match 'unexpected_executed_tests')
  },
  [pscustomobject][ordered]@{
    name = 'r19_phase4_representatives_are_required'
    valid = ($runner -match 'UT-BULK-NEG-WIRE-001' -and
      $runner -match 'UT-HS-TDD-COORD-001' -and
      $runner -match 'UT-HS-PHASE6-ADAPTER-001' -and
      $runner -match 'UT-CONTROL-V2-VCBN-DEMUX-001')
  },
  [pscustomobject][ordered]@{
    name = 'r19_representatives_must_be_phase4_labeled'
    valid = ($runner -match 'required_phase4_missing_labels')
  },
  [pscustomobject][ordered]@{
    name = 'summary_declares_all_registered_test_selection'
    valid = ($runner -match "ctest_filter\s*=\s*'all_registered_tests'")
  },
  [pscustomobject][ordered]@{
    name = 'dynamic_fake_toolchain_full_suite_pass'
    valid = $dynamic.passed
  }
)
$failed = @($checks | Where-Object { -not $_.valid })
$summary = [ordered]@{
  schema_version = 1
  test = 'HOST-SANITIZER-FULL-SUITE-RUNNER-001'
  result = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
  finished_utc = [DateTime]::UtcNow.ToString('o')
  hardware_interaction = $false
  network_interaction = $false
  long_sanitizer_suite_executed = $false
  runner = $runnerPath
  runner_sha256 = (Get-FileHash -LiteralPath $runnerPath `
      -Algorithm SHA256).Hash
  dynamic_fixture = $dynamic
  checks = $checks
  failures = @($failed | ForEach-Object { $_.name })
}
[IO.File]::WriteAllText(
  (Join-Path $OutputDirectory 'summary.json'),
  (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
  $utf8
)
if ($failed.Count -ne 0) {
  Write-Host ("FAIL HOST-SANITIZER-FULL-SUITE-RUNNER-001 " +
    "failures=$($failed.Count) evidence=$OutputDirectory")
  foreach ($failure in $failed) {
    Write-Host "  $($failure.name)"
  }
  exit 1
}
Write-Host ("PASS HOST-SANITIZER-FULL-SUITE-RUNNER-001 " +
  "evidence=$OutputDirectory")
