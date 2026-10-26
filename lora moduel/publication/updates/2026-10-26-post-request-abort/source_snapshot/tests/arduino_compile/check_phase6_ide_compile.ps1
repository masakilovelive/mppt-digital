param(
  [string]$ArduinoCli,
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$ExpectedEsp32CoreVersion = '3.3.11',
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$IdeConfig = (Join-Path $env:USERPROFILE `
    '.arduinoIDE\arduino-cli.yaml')
)

$ErrorActionPreference = 'Stop'

if (-not $ArduinoCli) {
  $ArduinoCli = Join-Path $env:TEMP `
    'arduino-cli-vc-lora-check\arduino-cli.exe'
}
if (-not (Test-Path -LiteralPath $ArduinoCli)) {
  $found = Get-Command arduino-cli -ErrorAction SilentlyContinue
  if (-not $found) {
    throw 'FW-ARDUINO-IDE-001: arduino-cli not found'
  }
  $ArduinoCli = $found.Source
}

$globalArgs = @()
if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig)) {
  $globalArgs += @('--config-file', $IdeConfig)
}
$boardDetails = (& $ArduinoCli @globalArgs board details --fqbn $Fqbn `
  --format json | ConvertFrom-Json)
if ($boardDetails.version -cne $ExpectedEsp32CoreVersion) {
  throw "FW-ARDUINO-IDE-001: expected ESP32 core $ExpectedEsp32CoreVersion, got $($boardDetails.version)"
}
$hwcdcContractCheck = Join-Path $RepoRoot `
  'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1'
& $hwcdcContractCheck -ArduinoCli $ArduinoCli -Fqbn $Fqbn `
  -ExpectedCoreVersion $ExpectedEsp32CoreVersion -IdeConfig $IdeConfig
if (-not $?) { exit 1 }
$runToken = $PID

function Invoke-IdeEquivalentCompile {
  param(
    [string]$Role,
    [string]$Sketch
  )

  $roleLower = $Role.ToLowerInvariant()
  $buildPath = Join-Path $env:TEMP `
    "vc_lora_ide_${roleLower}_$runToken"
  $compileOutput = @(& $ArduinoCli @globalArgs compile `
    --fqbn $Fqbn --warnings all --clean --build-path $buildPath `
    --json $Sketch 2>&1)
  $compileExit = $LASTEXITCODE
  $compileText = $compileOutput -join "`n"
  try {
    $compileResult = $compileText | ConvertFrom-Json
  } catch {
    Write-Host $compileText
    throw "FW-ARDUINO-IDE-001: $Role compile returned invalid JSON"
  }

  if ($compileExit -ne 0 -or -not $compileResult.success) {
    if ($compileResult.compiler_out) {
      Write-Host $compileResult.compiler_out.TrimEnd()
    }
    if ($compileResult.compiler_err) {
      Write-Host $compileResult.compiler_err.TrimEnd()
    }
    throw "FW-ARDUINO-IDE-001: $Role direct-open compile failed"
  }

  $binary = Join-Path $buildPath `
    ((Split-Path -Leaf $Sketch) + '.ino.bin')
  if (-not (Test-Path -LiteralPath $binary)) {
    throw "FW-ARDUINO-IDE-001: $Role compile produced no application binary"
  }

  $flash = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'text' })[0]
  $ram = @($compileResult.builder_result.executable_sections_size |
    Where-Object { $_.name -eq 'data' })[0]
  if (-not $flash -or -not $ram) {
    throw "FW-ARDUINO-IDE-001: $Role compile returned no size data"
  }
  Write-Output ("FW-ARDUINO-IDE-001 {0} PASS flash={1} ram={2}" -f `
    $Role, $flash.size, $ram.size)
}

$vehicle = Join-Path $RepoRoot 'vc_lora_vehicle_xiao_esp32s3'
$ground = Join-Path $RepoRoot 'vc_lora_ground_xiao_esp32s3'

# Sequential by contract: the ESP32 Arduino cache is shared between roles.
Invoke-IdeEquivalentCompile 'Vehicle' $vehicle
Invoke-IdeEquivalentCompile 'Ground' $ground

Write-Output 'FW-ARDUINO-IDE-001 PASS'
