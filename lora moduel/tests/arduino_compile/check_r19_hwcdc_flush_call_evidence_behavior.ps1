param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$Compiler = '',
  [string]$OutputDir = ''
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$sdk = Join-Path $repo 'third_party\esp32-core-3.3.11-vc-lora\cores\esp32'
$sourcePath = Join-Path $sdk 'HWCDC.cpp'
$source = Get-Content -LiteralPath $sourcePath -Raw
function Get-ActualFunction([string]$Name) {
  $start = $source.IndexOf($Name, [StringComparison]::Ordinal)
  if ($start -lt 0) { throw "Missing actual SDK function: $Name" }
  $opening = $source.IndexOf('{', $start)
  $depth = 1
  for ($index = $opening + 1; $index -lt $source.Length; $index++) {
    if ($source[$index] -eq '{') { $depth++ }
    if ($source[$index] -eq '}') { $depth-- }
    if ($depth -eq 0) { return $source.Substring($start, $index - $start + 1) }
  }
  throw "Unterminated actual SDK function: $Name"
}
$legacy = Get-ActualFunction 'bool HWCDC::flushTxComplete('
$diagnostic = Get-ActualFunction 'bool HWCDC::flushTxCompleteDiagnostic('
$header = Get-Content -LiteralPath (Join-Path $sdk 'HWCDC.h') -Raw
if ($header -notmatch '(?s)#if defined\(VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS\).*?flushTxCompleteDiagnostic') {
  throw 'New API is not macro-scoped in the SDK header'
}
if ([string]::IsNullOrWhiteSpace($Compiler)) {
  $found = Get-Command clang++ -ErrorAction SilentlyContinue
  if ($null -ne $found) { $Compiler = $found.Source }
}
if ([string]::IsNullOrWhiteSpace($Compiler)) {
  $Compiler = Join-Path $env:TEMP 'vc_lora_host_tools\llvm-mingw-20260616-complete\unpacked\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
}
$compilerPath = (Resolve-Path -LiteralPath $Compiler -ErrorAction Stop).Path
$temporary = [string]::IsNullOrWhiteSpace($OutputDir)
if ($temporary) {
  $OutputDir = Join-Path ([IO.Path]::GetTempPath()) ('r19_flush_call_' + [Guid]::NewGuid().ToString('N'))
}
$output = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$originalPath = $env:PATH
try {
  $env:PATH = (Split-Path -Parent $compilerPath) + ';' + $originalPath
  $template = Get-Content -LiteralPath (Join-Path $repo 'tests\host\standalone\r19_hwcdc_flush_call_evidence_actual_template.cpp') -Raw
  $actual = $template.Replace('// @ACTUAL_LEGACY_FUNCTION@', $legacy).
    Replace('// @ACTUAL_DIAGNOSTIC_FUNCTION@', $diagnostic)
  $fixture = Join-Path $output 'actual_hwcdc_flush_call.cpp'
  [IO.File]::WriteAllText($fixture, $actual, $utf8)
  $executable = Join-Path $output 'actual_hwcdc_flush_call.exe'
  $compile = @(& $compilerPath '-std=c++17' '-O0' '-Wall' '-Wextra' '-Werror' "-I$sdk" $fixture '-o' $executable 2>&1)
  $compileExit = $LASTEXITCODE
  [IO.File]::WriteAllText((Join-Path $output 'compile.txt'), ($compile -join "`n"), $utf8)
  if ($compileExit -ne 0) { throw ('Actual SDK fixture compile failed: ' + ($compile -join "`n")) }
  $result = @(& $executable 2>&1)
  $runExit = $LASTEXITCODE
  [IO.File]::WriteAllText((Join-Path $output 'run.txt'), ($result -join "`n"), $utf8)
  $summary = [pscustomobject][ordered]@{
    schema = 'vc-lora-r19-hwcdc-flush-call-evidence-actual-v1'
    result = if ($runExit -eq 0) { 'PASS' } else { 'FAIL' }
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    diagnostic_header_sha256 = (Get-FileHash -LiteralPath (Join-Path $sdk 'HWCDCR19Diagnostic.h') -Algorithm SHA256).Hash
    compiler_sha256 = (Get-FileHash -LiteralPath $compilerPath -Algorithm SHA256).Hash
    source = 'actual SDK method bodies extracted verbatim; deterministic OS/LL shims only'
    hardware_interaction = $false
    compile_exit_code = $compileExit
    run_exit_code = $runExit
    output = $result
  }
  [IO.File]::WriteAllText((Join-Path $output 'summary.json'), ($summary | ConvertTo-Json -Depth 8), $utf8)
  $result | Write-Output
  if ($runExit -ne 0) { throw 'Actual SDK flush-call evidence behavior failed' }
} finally {
  $env:PATH = $originalPath
  if ($temporary -and (Test-Path -LiteralPath $output)) {
    $resolved = (Resolve-Path -LiteralPath $output).Path
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\r19_flush_call_'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Unsafe fixture cleanup path'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
