[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Publication-copy verification only. No source edits, Arduino build,
# hardware access, network operation, or full 430-test rerun is performed.
$snapshotRoot = 'E:/VESC/_codex_build/mppt-lora-aux-20261022/lora moduel/publication/updates/2026-10-24-pregrant-fallback/source_snapshot'
$snapshotBuild = 'E:/VESC/_codex_build/lora-publication-checks-20261025-pregrant'
$cmakeBin = 'C:/Users/user/AppData/Local/Android/Sdk/cmake/3.22.1/bin'
$compilerBin = 'C:/Users/user/AppData/Local/Temp/vc_lora_host_tools/llvm-mingw-20260616-complete/unpacked/llvm-mingw-20260616-ucrt-x86_64/bin'
$windowsPowerShell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
$env:PATH = $compilerBin + ';' + $cmakeBin + ';' + $env:PATH
$filter = '^IT-R19-(PRENEGOTIATION-FALLBACK-.*|GRANT-DIAGNOSTIC-BRIDGE)-001$'

foreach ($leaf in @('configure_attempt1.log','build_attempt1.log','ctest_attempt1.log')) {
  if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $leaf)) {
    throw "Refusing to overwrite immutable first-attempt log: $leaf"
  }
}
if (Test-Path -LiteralPath $snapshotBuild) {
  throw 'Fresh build directory was expected; no deletion or reuse attempted.'
}

& ($cmakeBin + '/cmake.exe') -S $snapshotRoot -B $snapshotBuild -G Ninja `
  ('-DCMAKE_MAKE_PROGRAM=' + $cmakeBin + '/ninja.exe') `
  ('-DCMAKE_CXX_COMPILER=' + $compilerBin + '/clang++.exe') `
  ('-DVC_LORA_POWERSHELL_EXECUTABLE=' + $windowsPowerShell) `
  -DCMAKE_BUILD_TYPE=Debug -DVC_LORA_BUILD_TESTS=ON 2>&1 |
    Tee-Object -FilePath (Join-Path $PSScriptRoot 'configure_attempt1.log')
$configureExit = $LASTEXITCODE
Write-Output ('SNAPSHOT_CONFIGURE_EXIT=' + $configureExit)
if ($configureExit -ne 0) { exit $configureExit }

& ($cmakeBin + '/cmake.exe') --build $snapshotBuild --parallel 4 --target `
  vc_lora_r19_pre_negotiation_fallback_tests `
  vc_lora_phase6_grant_diagnostic_hooks_tests 2>&1 |
    Tee-Object -FilePath (Join-Path $PSScriptRoot 'build_attempt1.log')
$buildExit = $LASTEXITCODE
Write-Output ('SNAPSHOT_BUILD_EXIT=' + $buildExit)
if ($buildExit -ne 0) { exit $buildExit }

& ($cmakeBin + '/ctest.exe') --test-dir $snapshotBuild --output-on-failure `
  -R $filter -j 4 2>&1 |
    Tee-Object -FilePath (Join-Path $PSScriptRoot 'ctest_attempt1.log')
$ctestExit = $LASTEXITCODE
Write-Output ('SNAPSHOT_CTEST_EXIT=' + $ctestExit)
exit $ctestExit
