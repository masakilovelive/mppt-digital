param(
  [string]$CMake,
  [string]$CTest,
  [string]$Ninja,
  [string]$Compiler
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

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
  (Join-Path $env:TEMP 'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe')
)

$toolDirs = @(
  (Split-Path -Parent $compilerPath),
  (Split-Path -Parent $cmakePath),
  (Split-Path -Parent $ninjaPath)
)
$env:PATH = (($toolDirs + $env:PATH) -join ';')
$cmakeCompiler = $compilerPath.Replace('\', '/')
$cmakeNinja = $ninjaPath.Replace('\', '/')

& $cmakePath -S $repo -B "$repo\build\host" -G Ninja `
  "-DCMAKE_MAKE_PROGRAM=$cmakeNinja" `
  "-DCMAKE_CXX_COMPILER=$cmakeCompiler" `
  -DCMAKE_BUILD_TYPE=Debug -DVC_LORA_BUILD_TESTS=ON
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $cmakePath --build "$repo\build\host" --parallel 4
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $ctestPath --test-dir "$repo\build\host" --output-on-failure -j 4
$ctestExit = $LASTEXITCODE

$pythonPath = $null
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCommand) {
  $pythonPath = $pythonCommand.Source
}
if (-not $pythonPath) {
  $pythonCandidate = Join-Path $env:LOCALAPPDATA `
    'Programs\Python\Python312-32\python.exe'
  if (Test-Path -LiteralPath $pythonCandidate) {
    $pythonPath = $pythonCandidate
  }
}
if ($pythonPath) {
  & $pythonPath "$repo\tools\summarize_test_run.py" "$repo\runs" `
    --output "$repo\runs\summary.json"
  $summaryExit = $LASTEXITCODE
  if ($ctestExit -eq 0 -and $summaryExit -ne 0) {
    exit $summaryExit
  }
} else {
  Write-Warning 'Python not found; runs\summary.json was not aggregated.'
}
exit $ctestExit
