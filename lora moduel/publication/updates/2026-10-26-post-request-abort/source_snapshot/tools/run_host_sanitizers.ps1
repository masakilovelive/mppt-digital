param(
  [string]$CMake,
  [string]$CTest,
  [string]$Ninja,
  [string]$Compiler
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repo 'build\host-sanitize'
$runsDir = Join-Path $repo 'runs'
$summaryPath = Join-Path $runsDir 'host_full_sanitizer_summary.json'
$ctestLogPath = Join-Path $runsDir 'host_full_sanitizer_ctest.log'
$junitPath = Join-Path $runsDir 'host_full_sanitizer_junit.xml'
$requiredPhase4R19Tests = @(
  'UT-BULK-NEG-WIRE-001',
  'UT-HS-TDD-COORD-001',
  'UT-HS-PHASE6-ADAPTER-001',
  'UT-CONTROL-V2-VCBN-DEMUX-001'
)

function Find-Tool([string]$Explicit, [string]$Command,
                   [string[]]$Fallbacks) {
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit)) {
      throw "Tool not found: $Explicit"
    }
    return (Resolve-Path -LiteralPath $Explicit).Path
  }

  $found = Get-Command $Command -ErrorAction SilentlyContinue
  if ($found) { return $found.Source }

  foreach ($candidate in $Fallbacks) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  throw "Required tool not found: $Command"
}

function Reset-FreshBuildDirectory([string]$RepoRoot,
                                   [string]$BuildDirectory) {
  $expected = [IO.Path]::GetFullPath(
    (Join-Path $RepoRoot 'build\host-sanitize'))
  $actual = [IO.Path]::GetFullPath($BuildDirectory)
  $repoPrefix = [IO.Path]::GetFullPath($RepoRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  ) + [IO.Path]::DirectorySeparatorChar
  if (-not $actual.StartsWith(
      $repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset sanitizer build outside repository: $actual"
  }
  if (-not $actual.Equals(
      $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset unexpected sanitizer build path: $actual"
  }
  if (Test-Path -LiteralPath $BuildDirectory) {
    Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
  }
}

function Invoke-NativeCapture([string]$FilePath, [string[]]$Arguments) {
  # Windows PowerShell 5.1 turns redirected native stderr into ErrorRecord
  # objects.  With the script-wide Stop preference, an expected non-zero
  # CTest result would abort before its JUnit/log evidence is persisted.
  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  foreach ($line in $output) {
    Write-Host $line
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { $_.ToString() })
  }
}

function Read-JUnit([string]$Path) {
  $result = [ordered]@{
    total = 0
    passed = 0
    failed = 0
    skipped = 0
    cases = @()
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    return $result
  }

  [xml]$document = Get-Content -Raw -LiteralPath $Path
  $suite = $document.testsuite
  if (-not $suite) {
    return $result
  }

  $cases = @($suite.testcase)
  $caseResults = @()
  $failed = 0
  $skipped = 0
  foreach ($case in $cases) {
    $status = 'passed'
    if ($case.failure -or $case.error) {
      $status = 'failed'
      $failed++
    } elseif ($case.skipped) {
      $status = 'skipped'
      $skipped++
    }
    $caseResults += [ordered]@{
      name = [string]$case.name
      status = $status
      time_seconds = [double]$case.time
    }
  }

  $result['total'] = $cases.Count
  $result['failed'] = $failed
  $result['skipped'] = $skipped
  $result['passed'] = $cases.Count - $failed - $skipped
  $result['cases'] = $caseResults
  return $result
}

New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
foreach ($generatedPath in @($junitPath, $ctestLogPath)) {
  if (Test-Path -LiteralPath $generatedPath) {
    Remove-Item -LiteralPath $generatedPath -Force
  }
}

$startedUtc = (Get-Date).ToUniversalTime()
$scriptExit = 1
$summary = [ordered]@{
  schema_version = 1
  suite = 'host_full_sanitizers'
  status = 'FAIL'
  started_utc = $startedUtc.ToString('o')
  finished_utc = $null
  duration_seconds = 0.0
  build_directory = $buildDir
  compiler = $null
  compiler_version = $null
  sanitizer = [ordered]@{
    instrumentation = 'address,undefined'
    asan_options = 'detect_leaks=0:halt_on_error=1'
    ubsan_options = 'halt_on_error=1:print_stacktrace=1'
    address_sanitizer_reports = $null
    undefined_behavior_reports = $null
  }
  configure_exit_code = $null
  build_exit_code = $null
  registry_exit_code = $null
  ctest_exit_code = $null
  ctest_filter = 'all_registered_tests'
  ctest_parallel = 1
  coverage = [ordered]@{
    registered_test_count = 0
    executed_test_count = 0
    required_phase4_r19_tests = $requiredPhase4R19Tests
    required_phase4_missing_from_registry = @()
    required_phase4_missing_labels = @()
    required_phase4_missing_from_junit = @()
    missing_registered_tests = @()
    unexpected_executed_tests = @()
  }
  tests = [ordered]@{
    total = 0
    passed = 0
    failed = 0
    skipped = 0
    cases = @()
  }
  junit = $junitPath
  ctest_log = $ctestLogPath
  error = $null
}

try {
  $cmakePath = Find-Tool $CMake 'cmake' @(
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\cmake\3.22.1\bin\cmake.exe')
  )
  $ctestPath = Find-Tool $CTest 'ctest' @(
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\cmake\3.22.1\bin\ctest.exe')
  )
  $ninjaPath = Find-Tool $Ninja 'ninja' @(
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\cmake\3.22.1\bin\ninja.exe')
  )
  $compilerPath = Find-Tool $Compiler 'clang++' @(
    (Join-Path $env:TEMP `
      'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe')
  )

  $compilerVersionResult = Invoke-NativeCapture $compilerPath @('--version')
  if ($compilerVersionResult.ExitCode -ne 0) {
    throw "Unable to query compiler version (exit $($compilerVersionResult.ExitCode))"
  }
  $compilerVersion = ($compilerVersionResult.Output -join "`n").Trim()
  if ($compilerVersion -notmatch '(?m)^clang version 22\.') {
    throw 'Phase 5 sanitizer run requires llvm-mingw clang 22.x'
  }

  $resourceResult = Invoke-NativeCapture $compilerPath @('-print-resource-dir')
  if ($resourceResult.ExitCode -ne 0 -or $resourceResult.Output.Count -eq 0) {
    throw 'Unable to locate the clang sanitizer runtime directory'
  }
  $resourceDir = $resourceResult.Output[0].Trim()
  $toolchainRoot = Split-Path -Parent `
    (Split-Path -Parent (Split-Path -Parent $resourceDir))
  $asanRuntimeCandidates = @(
    (Join-Path (Split-Path -Parent $compilerPath) `
      'libclang_rt.asan_dynamic-x86_64.dll'),
    (Join-Path $toolchainRoot `
      'x86_64-w64-mingw32\bin\libclang_rt.asan_dynamic-x86_64.dll')
  )
  $asanRuntime = $asanRuntimeCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
  if (-not $asanRuntime) {
    throw 'llvm-mingw x86_64 AddressSanitizer runtime DLL was not found'
  }

  $toolDirs = @(
    (Split-Path -Parent $compilerPath),
    (Split-Path -Parent $asanRuntime),
    (Split-Path -Parent $cmakePath),
    (Split-Path -Parent $ninjaPath)
  )
  $env:PATH = (($toolDirs + $env:PATH) -join ';')
  $env:ASAN_OPTIONS = $summary.sanitizer.asan_options
  $env:UBSAN_OPTIONS = $summary.sanitizer.ubsan_options
  $symbolizer = Join-Path (Split-Path -Parent $compilerPath) `
    'llvm-symbolizer.exe'
  if (Test-Path -LiteralPath $symbolizer) {
    $env:LLVM_SYMBOLIZER_PATH = $symbolizer
  }

  $summary['compiler'] = $compilerPath
  $summary['compiler_version'] = ($compilerVersion -split "`n")[0]
  $cmakeCompiler = $compilerPath.Replace('\', '/')
  $cmakeNinja = $ninjaPath.Replace('\', '/')

  Reset-FreshBuildDirectory $repo $buildDir

  $configure = Invoke-NativeCapture $cmakePath @(
    '-S', $repo,
    '-B', $buildDir,
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$cmakeNinja",
    "-DCMAKE_CXX_COMPILER=$cmakeCompiler",
    '-DCMAKE_BUILD_TYPE=Debug',
    '-DVC_LORA_BUILD_TESTS=ON',
    '-DVC_LORA_ENABLE_SANITIZERS=ON'
  )
  $summary['configure_exit_code'] = $configure.ExitCode
  if ($configure.ExitCode -ne 0) {
    throw "Sanitizer configure failed (exit $($configure.ExitCode))"
  }

  $build = Invoke-NativeCapture $cmakePath @(
    '--build', $buildDir, '--parallel', '4'
  )
  $summary['build_exit_code'] = $build.ExitCode
  if ($build.ExitCode -ne 0) {
    throw "Sanitizer build failed (exit $($build.ExitCode))"
  }

  $registryRun = Invoke-NativeCapture $ctestPath @(
    '--test-dir', $buildDir,
    '--show-only=json-v1'
  )
  $summary['registry_exit_code'] = $registryRun.ExitCode
  if ($registryRun.ExitCode -ne 0) {
    throw "Unable to enumerate sanitizer tests (exit $($registryRun.ExitCode))"
  }
  try {
    $registry = ($registryRun.Output -join "`n") | ConvertFrom-Json
  } catch {
    throw "Unable to parse sanitizer CTest registry: $($_.Exception.Message)"
  }
  $registeredTests = @($registry.tests)
  $registeredNames = @($registeredTests | ForEach-Object {
      [string]$_.name
    })
  $summary.coverage.registered_test_count = $registeredNames.Count
  if ($registeredNames.Count -eq 0) {
    throw 'No tests were registered in the sanitizer build'
  }

  $missingRequired = @($requiredPhase4R19Tests | Where-Object {
      $registeredNames -notcontains $_
    })
  $missingPhase4Labels = @()
  foreach ($requiredName in $requiredPhase4R19Tests) {
    $registeredTest = @($registeredTests | Where-Object {
        [string]$_.name -eq $requiredName
      } | Select-Object -First 1)
    if ($registeredTest.Count -eq 0) {
      continue
    }
    $labels = @()
    foreach ($property in @($registeredTest[0].properties)) {
      if ([string]$property.name -eq 'LABELS') {
        $labels += @($property.value)
      }
    }
    if ($labels -notcontains 'phase4') {
      $missingPhase4Labels += $requiredName
    }
  }
  $summary.coverage.required_phase4_missing_from_registry = $missingRequired
  $summary.coverage.required_phase4_missing_labels = $missingPhase4Labels
  if ($missingRequired.Count -ne 0) {
    throw ("Required R19 Phase 4 tests are absent from the registry: " +
      ($missingRequired -join ', '))
  }
  if ($missingPhase4Labels.Count -ne 0) {
    throw ("Required R19 tests do not carry the phase4 label: " +
      ($missingPhase4Labels -join ', '))
  }

  $ctestRun = Invoke-NativeCapture $ctestPath @(
    '--test-dir', $buildDir,
    '--output-on-failure',
    '--output-junit', $junitPath,
    '-j', '1'
  )
  $summary['ctest_exit_code'] = $ctestRun.ExitCode
  Set-Content -LiteralPath $ctestLogPath -Encoding UTF8 `
    -Value ($ctestRun.Output -join [Environment]::NewLine)
  $summary['tests'] = Read-JUnit $junitPath
  $ctestText = $ctestRun.Output -join "`n"
  $summary.sanitizer.address_sanitizer_reports = @(
    [regex]::Matches(
      $ctestText,
      '(?im)(ERROR: AddressSanitizer|AddressSanitizer:DEADLYSIGNAL)'
    )
  ).Count
  $summary.sanitizer.undefined_behavior_reports = @(
    [regex]::Matches(
      $ctestText,
      '(?im)(UndefinedBehaviorSanitizer|runtime error:)'
    )
  ).Count

  $executedNames = @($summary.tests.cases | ForEach-Object {
      [string]$_.name
    })
  $summary.coverage.executed_test_count = $executedNames.Count
  $summary.coverage.required_phase4_missing_from_junit = @(
    $requiredPhase4R19Tests | Where-Object {
      $executedNames -notcontains $_
    }
  )
  $summary.coverage.missing_registered_tests = @(
    $registeredNames | Where-Object {
      $executedNames -notcontains $_
    }
  )
  $summary.coverage.unexpected_executed_tests = @(
    $executedNames | Where-Object {
      $registeredNames -notcontains $_
    }
  )

  if ($ctestRun.ExitCode -ne 0) {
    throw "Full host sanitizer tests failed (exit $($ctestRun.ExitCode))"
  }
  if ($summary.tests.total -eq 0) {
    throw 'Full host sanitizer run produced no JUnit test cases'
  }
  if ($summary.tests.failed -ne 0 -or $summary.tests.skipped -ne 0) {
    throw 'Full host sanitizer run did not pass every registered test'
  }
  if ($summary.coverage.required_phase4_missing_from_junit.Count -ne 0) {
    throw ("Required R19 Phase 4 tests were not executed: " +
      ($summary.coverage.required_phase4_missing_from_junit -join ', '))
  }
  if ($summary.coverage.missing_registered_tests.Count -ne 0 -or
      $summary.coverage.unexpected_executed_tests.Count -ne 0) {
    throw 'Sanitizer registry and executed JUnit cases do not match exactly'
  }
  if ($summary.sanitizer.address_sanitizer_reports -ne 0 -or
      $summary.sanitizer.undefined_behavior_reports -ne 0) {
    throw 'Sanitizer diagnostics were present in the full host test output'
  }

  $summary['status'] = 'PASS'
  $scriptExit = 0
} catch {
  $summary['error'] = $_.Exception.Message
  Write-Error $_.Exception.Message -ErrorAction Continue
} finally {
  $finishedUtc = (Get-Date).ToUniversalTime()
  $summary['finished_utc'] = $finishedUtc.ToString('o')
  $summary['duration_seconds'] = [math]::Round(
    ($finishedUtc - $startedUtc).TotalSeconds, 3
  )
  $summary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8
  Write-Host "Sanitizer summary: $summaryPath"
}

exit $scriptExit
