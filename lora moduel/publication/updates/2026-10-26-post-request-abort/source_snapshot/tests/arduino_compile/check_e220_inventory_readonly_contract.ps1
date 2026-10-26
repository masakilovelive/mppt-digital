param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [switch]$SkipCompile,
  [string]$ArduinoCli = (Join-Path $env:TEMP 'arduino-cli-vc-lora-check\arduino-cli.exe'),
  [string]$Fqbn = 'esp32:esp32:XIAO_ESP32S3',
  [string]$IdeConfig = "$env:USERPROFILE\.arduinoIDE\arduino-cli.yaml",
  [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$testId = 'FW-E220-INVENTORY-READONLY-001'

function Require-Text {
  param([string]$Path, [string]$Pattern, [string]$Description)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$testId`: missing $Description at $Path"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text -notmatch $Pattern) {
    throw "$testId`: $Description does not satisfy /$Pattern/"
  }
}

function Reject-Text {
  param([string]$Path, [string]$Pattern, [string]$Description)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$testId`: missing $Description at $Path"
  }
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text -match $Pattern) {
    throw "$testId`: $Description unexpectedly matches /$Pattern/"
  }
}

$sketchRoot = Join-Path $RepoRoot 'vc_lora_e220_inventory_xiao_esp32s3'
$sketch = Join-Path $sketchRoot 'vc_lora_e220_inventory_xiao_esp32s3.ino'

if (-not (Test-Path -LiteralPath $sketch -PathType Leaf)) {
  throw "$testId`: missing read-only inventory sketch at $sketch"
}

foreach ($pin in @(
    @('E220_M0_PIN', 'D0'),
    @('E220_M1_PIN', 'D1'),
    @('E220_TX_PIN', 'D2'),
    @('E220_RX_PIN', 'D3'),
    @('E220_AUX_PIN', 'D8')
  )) {
  Require-Text $sketch ("static\s+constexpr\s+int\s+{0}\s*=\s*{1}\s*;" -f
      $pin[0], $pin[1]) "fixed $($pin[0])=$($pin[1]) pin binding"
}

Require-Text $sketch 'HardwareSerial\s+E220Serial\s*\(\s*1\s*\)' `
  'dedicated E220 UART1'
Require-Text $sketch `
  'E220Serial\.begin\s*\(\s*E220_CONFIG_BAUD\s*,\s*SERIAL_8N1\s*,\s*E220_RX_PIN\s*,\s*E220_TX_PIN\s*\)' `
  '9600 8N1 configuration UART binding'
Require-Text $sketch 'E220_CONFIG_BAUD\s*=\s*9600(?:U|UL)?\s*;' `
  'fixed 9600 configuration baud'

$text = Get-Content -Raw -LiteralPath $sketch
$commandMatches = [regex]::Matches(
  $text,
  'static\s+constexpr\s+uint8_t\s+\w+\s*\[\s*3\s*\]\s*=\s*\{\s*0xC1\s*,\s*0x([0-9A-Fa-f]{2})\s*,\s*0x([0-9A-Fa-f]{2})\s*\}\s*;')
$commands = @($commandMatches | ForEach-Object {
    ('C1{0}{1}' -f $_.Groups[1].Value.ToUpperInvariant(),
      $_.Groups[2].Value.ToUpperInvariant())
  })
if ($commands.Count -ne 2 -or
    @($commands | Where-Object { $_ -ceq 'C10008' }).Count -ne 1 -or
    @($commands | Where-Object { $_ -ceq 'C10801' }).Count -ne 1) {
  throw "$testId`: command inventory must contain exactly C1 00 08 and C1 08 01"
}

Reject-Text $sketch '\b0xC0\b|\b0xC2\b' `
  'configuration write opcode'
Reject-Text $sketch `
  '\b(?:Preferences|EEPROM|nvs_flash|nvs_set|putBytes|putUChar|write_e220|set_e220_(?:profile|baud|channel))\b' `
  'persistent or temporary configuration mutation surface'
Reject-Text $sketch 'E220Serial\s*\.\s*(?:print|println|printf)\s*\(' `
  'unrestricted text transmission to E220'

$writes = [regex]::Matches($text, 'E220Serial\s*\.\s*write\s*\(')
if ($writes.Count -ne 1) {
  throw "$testId`: E220 UART must have exactly one guarded write call, got $($writes.Count)"
}
Require-Text $sketch `
  'static\s+bool\s+send_read_command\s*\(\s*const\s+uint8_t\s*\(\s*&command\s*\)\s*\[\s*3\s*\][\s\S]{0,1800}command\s*\[\s*0\s*\]\s*!=\s*0xC1[\s\S]{0,500}E220Serial\.write\s*\(\s*command\s*,\s*sizeof\s*\(\s*command\s*\)\s*\)' `
  'single guarded exact-length C1 read command transmitter'
Require-Text $sketch `
  'UART_SHIFT_DRAIN_MS\s*=\s*(?:[4-9]|[1-9][0-9]+)(?:U|UL)?\s*;' `
  'bounded UART shifter drain interval'
Require-Text $sketch `
  'E220Serial\.write\s*\(\s*command\s*,\s*sizeof\s*\(\s*command\s*\)\s*\)[\s\S]{0,350}delay\s*\(\s*UART_SHIFT_DRAIN_MS\s*\)[\s\S]{0,350}wait_aux_high\s*\(\s*AUX_TIMEOUT_MS\s*\)' `
  'bounded UART drain before post-request AUX readiness sample'
Reject-Text $sketch 'E220Serial\s*\.\s*flush\s*\(' `
  'unbounded HardwareSerial flush path'

Require-Text $sketch `
  'static\s+bool\s+wait_aux_high\s*\(\s*uint32_t\s+timeout_ms\s*\)[\s\S]{0,600}millis\s*\(\s*\)\s*-\s*start_ms\s*>=\s*timeout_ms' `
  'bounded AUX HIGH wait'
Require-Text $sketch `
  'static\s+size_t\s+collect_response\s*\([^)]*uint32_t\s+timeout_ms\s*\)[\s\S]{0,1000}millis\s*\(\s*\)\s*-\s*start_ms\s*<\s*timeout_ms' `
  'bounded response collection'
Require-Text $sketch 'AUX_TIMEOUT_MS\s*=\s*[1-9][0-9]{1,4}(?:U|UL)?\s*;' `
  'finite AUX timeout constant'
Require-Text $sketch 'RESPONSE_TIMEOUT_MS\s*=\s*[1-9][0-9]{1,4}(?:U|UL)?\s*;' `
  'finite response timeout constant'
Reject-Text $sketch 'while\s*\(\s*(?:true|1)\s*\)' 'unbounded busy loop'

Require-Text $sketch `
  'static\s+void\s+set_normal_mode\s*\(\s*\)[\s\S]{0,350}digitalWrite\s*\(\s*E220_M0_PIN\s*,\s*LOW\s*\)[\s\S]{0,200}digitalWrite\s*\(\s*E220_M1_PIN\s*,\s*LOW\s*\)' `
  'normal-mode restoration implementation'
Require-Text $sketch `
  'static\s+bool\s+set_configuration_mode\s*\(\s*\)[\s\S]{0,500}wait_aux_high\s*\(\s*AUX_TIMEOUT_MS\s*\)[\s\S]{0,350}digitalWrite\s*\(\s*E220_M0_PIN\s*,\s*HIGH\s*\)[\s\S]{0,200}digitalWrite\s*\(\s*E220_M1_PIN\s*,\s*HIGH\s*\)' `
  'bounded AUX-idle gate before configuration-mode transition'
Require-Text $sketch `
  'MODE_POST_AUX_SETTLE_MS\s*=\s*(?:[2-9]|[1-9][0-9]+)(?:U|UL)?\s*;' `
  'at-least-2-ms post-AUX mode-settle constant'
Require-Text $sketch `
  'static\s+void\s+set_normal_mode\s*\(\s*\)[\s\S]{0,700}wait_aux_high\s*\(\s*AUX_TIMEOUT_MS\s*\)[\s\S]{0,250}delay\s*\(\s*MODE_POST_AUX_SETTLE_MS\s*\)[\s\S]{0,250}digitalRead\s*\(\s*E220_AUX_PIN\s*\)\s*==\s*HIGH' `
  'normal-mode AUX settle and recheck proof'
Require-Text $sketch `
  'probe_registers\s*\(\s*READ_CONFIGURATION\s*\)[\s\S]{0,500}probe_registers\s*\(\s*READ_PRODUCT_INFORMATION\s*\)[\s\S]{0,500}set_normal_mode\s*\(\s*\)' `
  'both read probes followed by normal-mode restoration'

foreach ($field in @(
    'schema', 'role', 'nonce', 'event', 'probe', 'request_hex', 'raw_hex',
    'valid', 'uart_bps', 'uart_format', 'air_bps', 'subpacket_bytes',
    'tx_power_dbm', 'channel', 'product_information_hex', 'crypt_readable',
    'crypt_hex', 'model', 'model_identification', 'normal_mode_restored'
  )) {
  Require-Text $sketch ('\\"{0}\\"' -f [regex]::Escape($field)) `
    "machine-readable output field $field"
}
Require-Text $sketch 'esp_random\s*\(\s*\)' 'per-boot nonce source'
Require-Text $sketch `
  'READY_INTERVAL_MS\s*=\s*[1-9][0-9]{1,4}(?:U|UL)?\s*;' `
  'bounded repeated READY interval'
Require-Text $sketch `
  'static\s+void\s+emit_ready\s*\(\s*\)[\s\S]{0,900}\\"boot_nonce\\"[\s\S]{0,500}\\"event\\":\\"ready\\"' `
  'repeated boot-anchored READY record'
Require-Text $sketch `
  'static\s+bool\s+parse_run_command\s*\([^)]*\)[\s\S]{0,1800}(?:RUN|run)[\s\S]{0,900}(?:isxdigit|is_hex_digit)' `
  'strict host RUN nonce parser'
Require-Text $sketch `
  'if\s*\(\s*!run_started\s*\)[\s\S]{0,1600}emit_ready\s*\(\s*\)[\s\S]{0,1800}parse_run_command\s*\([^)]*\)[\s\S]{0,900}run_inventory\s*\(\s*\)' `
  'host-armed inventory execution after READY'
Require-Text $sketch `
  'static\s+void\s+run_inventory\s*\(\s*\)[\s\S]{0,900}configuration_mode_ready\s*=\s*set_configuration_mode\s*\(\s*\)[\s\S]{0,1000}if\s*\(\s*configuration_mode_ready\s*\)[\s\S]{0,900}probe_registers\s*\(\s*READ_CONFIGURATION\s*\)[\s\S]{0,600}probe_registers\s*\(\s*READ_PRODUCT_INFORMATION\s*\)[\s\S]{0,800}set_normal_mode\s*\(\s*\)' `
  'single host-armed bounded read sequence with normal-mode restoration'
Require-Text $sketch `
  'print_json_prefix\s*\(\s*"ack"\s*\)' `
  'host nonce acknowledgement record'
Reject-Text $sketch `
  'void\s+setup\s*\(\s*\)[\s\S]{0,2600}set_configuration_mode\s*\(\s*\)' `
  'unarmed E220 configuration-mode transition during setup'
Require-Text $sketch 'VC_LORA_E220_INVENTORY_ROLE' `
  'build-bound role label'
Require-Text $sketch `
  '#ifndef\s+VC_LORA_E220_INVENTORY_ROLE[\s\S]{0,160}#error' `
  'mandatory explicit role build contract'
Require-Text $sketch `
  '#if\s+VC_LORA_E220_INVENTORY_ROLE\s*==\s*1[\s\S]{0,180}INVENTORY_ROLE\s*\[\s*\]\s*=\s*"ground"[\s\S]{0,180}#elif\s+VC_LORA_E220_INVENTORY_ROLE\s*==\s*2[\s\S]{0,180}INVENTORY_ROLE\s*\[\s*\]\s*=\s*"vehicle"[\s\S]{0,180}#error' `
  'closed safe ground-or-vehicle JSON role mapping'
Reject-Text $sketch '"unassigned"' 'implicit inventory role fallback'
Require-Text $sketch '\\"crypt_readable\\":false' `
  'write-only crypt-register disclosure'
Require-Text $sketch '\\"crypt_hex\\":null' `
  'null crypt value for write-only registers'
Require-Text $sketch '\\"tx_power_dbm\\":null' `
  'model-dependent transmit-power ambiguity'
Require-Text $sketch '\\"model\\":null' `
  'undocumented version-to-model mapping ambiguity'
Require-Text $sketch `
  '\\"model_identification\\":\\"physical_label_required\\"' `
  'physical-label model identification requirement'
Reject-Text $sketch `
  'print_hex\s*\(\s*&?registers\s*\[\s*6\s*\]\s*,\s*2' `
  'misleading crypt-key readback decode'

if (-not $SkipCompile) {
  if (-not (Test-Path -LiteralPath $ArduinoCli -PathType Leaf)) {
    throw "$testId`: Arduino IDE bundled CLI not found at $ArduinoCli"
  }
  $globalArgs = @()
  if ($IdeConfig -and (Test-Path -LiteralPath $IdeConfig -PathType Leaf)) {
    $globalArgs += @('--config-file', $IdeConfig)
  }
  if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP "vc_lora_e220_inventory_$PID"
  }
  [void][System.IO.Directory]::CreateDirectory($OutputDirectory)

  $compileEvidence = @()
  foreach ($role in @(
      [pscustomobject]@{ name = 'ground'; code = 1 },
      [pscustomobject]@{ name = 'vehicle'; code = 2 }
    )) {
    $roleRoot = Join-Path $OutputDirectory $role.name
    $buildPath = Join-Path $roleRoot 'build'
    $artifactPath = Join-Path $roleRoot 'firmware'
    [void][System.IO.Directory]::CreateDirectory($buildPath)
    [void][System.IO.Directory]::CreateDirectory($artifactPath)
    $roleFlag = 'compiler.cpp.extra_flags=-DVC_LORA_E220_INVENTORY_ROLE=' +
      $role.code
    $compileArguments = @($globalArgs + @(
        'compile', '--fqbn', $Fqbn, '--warnings', 'all', '--clean',
        '--build-path', $buildPath, '--output-dir', $artifactPath,
        '--build-property', $roleFlag, '--json', $sketchRoot
      ))
    $compileOutput = @(& $ArduinoCli @compileArguments 2>&1)
    $compileExit = $LASTEXITCODE
    $compileResult = (($compileOutput -join "`n") | ConvertFrom-Json)
    if ($compileExit -ne 0 -or -not $compileResult.success) {
      if ($compileResult.compiler_out) { Write-Host $compileResult.compiler_out }
      if ($compileResult.compiler_err) { Write-Host $compileResult.compiler_err }
      throw "$testId`: $($role.name) inventory sketch compile failed"
    }
    $binaryPath = Join-Path $artifactPath `
      'vc_lora_e220_inventory_xiao_esp32s3.ino.bin'
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
      throw "$testId`: $($role.name) binary was not exported"
    }
    $binaryFile = Get-Item -LiteralPath $binaryPath
    $compileEvidence += [ordered]@{
      role = $role.name
      role_code = $role.code
      binary_path = $binaryFile.FullName
      binary_size = $binaryFile.Length
      binary_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryPath).Hash
      compile_exit_code = $compileExit
    }
    Write-Output ("$testId COMPILE {0} PASS sha256={1}" -f
      $role.name, $compileEvidence[-1].binary_sha256)
  }

  $summary = [ordered]@{
    schema = 'e220_inventory_compile_v1'
    test_id = $testId
    result = 'PASS'
    fqbn = $Fqbn
    sketch_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sketch).Hash
    contract_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
    roles = $compileEvidence
  }
  $summaryPath = Join-Path $OutputDirectory 'compile_summary.json'
  $summaryJson = $summary | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText(
    $summaryPath, $summaryJson + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
  Write-Output "$testId COMPILE PASS summary=$summaryPath"
}

Write-Output "$testId PASS"
