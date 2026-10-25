param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$sketch = Join-Path $repo `
  'vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3\vc_lora_vehicle_pixhawk_param_benchmark_xiao_esp32s3.ino'

if (-not (Test-Path -LiteralPath $sketch -PathType Leaf)) {
  throw "FW-PIXHAWK-D7-PARAM-BENCH-001: missing benchmark sketch: $sketch"
}

$text = Get-Content -LiteralPath $sketch -Raw -Encoding UTF8

function Require-Pattern([string]$Pattern, [string]$Description) {
  if ($text -notmatch $Pattern) {
    throw "FW-PIXHAWK-D7-PARAM-BENCH-001: missing $Description"
  }
}

function Reject-Pattern([string]$Pattern, [string]$Description) {
  if ($text -match $Pattern) {
    throw "FW-PIXHAWK-D7-PARAM-BENCH-001: found $Description"
  }
}

function Require-InText([string]$InputText, [string]$Pattern,
                        [string]$Description) {
  if ($InputText -notmatch $Pattern) {
    throw "FW-PIXHAWK-D7-PARAM-BENCH-001: missing $Description"
  }
}

function Reject-InText([string]$InputText, [string]$Pattern,
                       [string]$Description) {
  if ($InputText -match $Pattern) {
    throw "FW-PIXHAWK-D7-PARAM-BENCH-001: found $Description"
  }
}

Require-Pattern 'kPixhawkRxPin\s*=\s*D7' 'D7 Pixhawk RX binding'
Require-Pattern 'kPixhawkTxPin\s*=\s*D6' 'D6 Pixhawk TX binding'
Require-Pattern 'kPixhawkBaud\s*=\s*57600U' 'fixed 57600-bps D7 benchmark'
Require-Pattern 'HardwareSerial\s+pixhawk_serial\s*\(\s*2\s*\)' `
  'isolated UART2 instance'
Require-Pattern 'kExpectedParameterCount\s*=\s*932U' `
  '932-parameter acceptance target'
Require-Pattern 'kBenchmarkTimeoutMs\s*=\s*120000U' `
  'bounded 120-second benchmark timeout'
Require-Pattern 'kIndexedQuietUs\s*=\s*2000000U' `
  'two-second indexed PARAM_VALUE quiet fence'
Require-Pattern 'kHeartbeatReadyMaxAgeUs\s*=\s*2500000U' `
  'fresh primary HEARTBEAT start gate'
Require-Pattern 'kHeartbeatMaximumGapUs\s*=\s*2500000U' `
  '2.5-second HEARTBEAT acceptance limit'
Require-Pattern 'kTarget10SecondsUs\s*=\s*10000000U' `
  'explicit ten-second performance target'
Require-Pattern 'kTarget30SecondsUs\s*=\s*30000000U' `
  'explicit thirty-second performance target'
Require-Pattern '0xFD(?:U)?\s*,\s*0x02(?:U)?\s*,\s*0x00(?:U)?\s*,\s*0x00(?:U)?\s*,\s*0x63(?:U)?\s*,\s*0xFF(?:U)?\s*,\s*0xBE(?:U)?\s*,\s*0x15(?:U)?\s*,\s*0x00(?:U)?\s*,\s*0x00(?:U)?\s*,\s*0x01(?:U)?\s*,\s*0x01(?:U)?\s*,\s*0xD5(?:U)?\s*,\s*0x07(?:U)?' `
  'golden MAVLink2 PARAM_REQUEST_LIST frame'
Require-Pattern 'pixhawk_serial\.write\s*\(\s*kParamRequestList\.data\s*\(\s*\)\s*,\s*kParamRequestList\.size\s*\(\s*\)\s*\)' `
  'golden request fixture as the actual UART write source'
Require-Pattern 'message_id\s*==\s*0U[\s\S]{0,120}extra\s*=\s*50U' `
  'HEARTBEAT CRC_EXTRA 50 validation'
Require-Pattern 'message_id\s*==\s*22U[\s\S]{0,120}extra\s*=\s*220U' `
  'PARAM_VALUE CRC_EXTRA 220 validation'
Require-Pattern 'crc_calculate\s*\(\s*frame\s*\+\s*1U\s*,\s*crc_input_size\s*,\s*extra\s*\)' `
  'MAVLink header-and-payload CRC calculation'
Require-Pattern 'kMaximumFrameBytes\s*=\s*280U' `
  'maximum signed MAVLink2 frame storage'
Require-Pattern 'expected_\s*=\s*static_cast\s*<\s*std::size_t\s*>\s*\(\s*buffer_\[1\]\s*\)\s*\+\s*12U\s*\+[\s\S]{0,160}\?\s*13U\s*:\s*0U' `
  'MAVLink2 payload and signature frame sizing'
Require-Pattern 'message_id\s*==\s*22U' 'PARAM_VALUE-only accounting'
Require-Pattern 'message_id\s*==\s*0U' 'primary HEARTBEAT accounting'
Require-Pattern 'param_count[\s\S]{0,180}payload\[4\][\s\S]{0,180}payload\[5\]' `
  'little-endian PARAM_VALUE count decode'
Require-Pattern 'param_index[\s\S]{0,180}payload\[6\][\s\S]{0,180}payload\[7\]' `
  'little-endian PARAM_VALUE index decode'
Require-Pattern 'is_exact_stat_runtime[\s\S]{0,1800}system_id\s*!=\s*1U[\s\S]{0,600}component_id\s*!=\s*1U[\s\S]{0,600}payload_length\s*!=\s*25U[\s\S]{0,1200}kExpectedParameterCount[\s\S]{0,500}0xFFFFU[\s\S]{0,900}kStatRuntimeId[\s\S]{0,500}payload\[24U\]\s*==\s*6U' `
  'exact source/count/index/id/type STAT_RUNTIME sentinel classifier'
Require-Pattern 'is_exact_stat_runtime\s*\(\s*frame\s*\)[\s\S]{0,220}stat_runtime_excluded' `
  'STAT_RUNTIME exclusion before indexed accounting'
Require-Pattern 'last_primary_indexed_parameter_us' `
  'global indexed PARAM_VALUE quiet observation'
Require-Pattern 'indexed_quiet_age_us[\s\S]{0,500}kIndexedQuietUs' `
  'indexed PARAM_VALUE quiet-age start decision'
Require-Pattern 'parser\.idle\s*\(\s*\)' 'parser boundary start gate'
Require-Pattern 'parser\.reset\s*\(\s*\)' 'explicit parser boundary reset'
Require-Pattern 'heartbeat_age_us[\s\S]{0,500}kHeartbeatReadyMaxAgeUs' `
  'primary HEARTBEAT freshness decision'
Require-Pattern 'previous_primary_heartbeat_us[\s\S]{0,600}kHeartbeatMaximumGapUs' `
  'two-recent-HEARTBEAT stability gate'
Require-Pattern 'pixhawk_serial\.available\s*\(\s*\)\s*!=\s*0' `
  'empty UART RX queue start fence'
Require-Pattern 'request_write_count\s*!=\s*0U' `
  'one-request-per-run guard'
Require-Pattern 'written\s*!=\s*kParamRequestList\.size\(\)' `
  'defensive Arduino write-length check'
Require-Pattern 'request_enqueue_us\s*=\s*now_us\s*\(\s*\)' `
  'request enqueue timestamp'
Require-Pattern 'pixhawk_serial\.flush\s*\(\s*\)' `
  'physical UART drain fence'
Require-Pattern 'request_tx_complete_us\s*=\s*now_us\s*\(\s*\)' `
  'request TX-complete timestamp'
Require-Pattern 'awaiting_post_list_heartbeat\s*=\s*true' `
  'post-list HEARTBEAT terminal wait state'
Require-Pattern 'post_list_heartbeat_us' `
  'post-list HEARTBEAT timestamp'
Require-Pattern 'nonce_valid[\s\S]{0,900}kNonceCapacity[\s\S]{0,1000}byte\s*==\s*''-''[\s\S]{0,160}byte\s*==\s*''_''[\s\S]{0,160}byte\s*==\s*''\.''' `
  'bounded machine-safe nonce validation'
Require-Pattern '\[READY\]' 'machine-readable readiness output'
Require-Pattern 'diagnostic=PIXHAWK_D7_PARAM_BENCHMARK_V2' `
  'versioned benchmark protocol identity'
Require-Pattern 'kProtocolIdentity\s*\[\s*\]\s*=\s*"PIXHAWK_D7_PARAM_BENCHMARK_V2"' `
  'single exact protocol identity constant'
Require-Pattern 'Serial\.print\s*\(\s*" protocol="\s*\)[\s\S]{0,160}Serial\.print\s*\(\s*kProtocolIdentity\s*\)' `
  'machine-readable exact protocol field writer'
foreach ($marker in @('BOOT', 'READY', 'START_ACK', 'PROGRESS', 'RESULT')) {
  Require-Pattern ("print_protocol_prefix\s*\(\s*`"\[{0}\]`"\s*\)" -f $marker) `
    "protocol identity on $marker output"
}
$usbCommandHandlerMatch = [regex]::Match(
  $text,
  'void\s+handle_usb_command\s*\([\s\S]*?(?=\r?\nvoid\s+service_usb\s*\()')
if (-not $usbCommandHandlerMatch.Success) {
  throw 'FW-PIXHAWK-D7-PARAM-BENCH-001: missing USB command handler body'
}
$usbCommandHandler = $usbCommandHandlerMatch.Value
Require-InText $usbCommandHandler `
  'std::strcmp\s*\(\s*line\s*,\s*"STATUS"\s*\)\s*==\s*0[\s\S]{0,160}print_ready\s*\(\s*\)' `
  'STATUS-command-driven READY output'

$setupMatch = [regex]::Match(
  $text,
  'void\s+setup\s*\(\s*\)\s*\{[\s\S]*?(?=\r?\n\}\s*\r?\n\s*void\s+loop\s*\()')
if (-not $setupMatch.Success) {
  throw 'FW-PIXHAWK-D7-PARAM-BENCH-001: missing setup body'
}
$setupBody = $setupMatch.Value
Require-InText $setupBody `
  'print_protocol_prefix\s*\(\s*"\[BOOT\]"\s*\)[\s\S]{0,200}diagnostic=PIXHAWK_D7_PARAM_BENCHMARK_V2' `
  'one-shot V2 BOOT output'
Reject-InText $setupBody 'print_ready\s*\(\s*\)' `
  'unsolicited setup READY output after BOOT'
$readyCallSites = [regex]::Matches(
  $text,
  '(?m)^\s*print_ready\s*\(\s*\)\s*;')
if ($readyCallSites.Count -ne 1) {
  throw 'FW-PIXHAWK-D7-PARAM-BENCH-001: READY must have exactly one STATUS-driven call site'
}
Require-Pattern '\[START_ACK\]' 'machine-readable start acknowledgement'
Require-Pattern '\[PROGRESS\]' 'machine-readable progress output'
Require-Pattern '\[RESULT\]' 'machine-readable terminal result'
foreach ($field in @(
    'missing=', 'duplicate=', 'out_of_order=', 'out_of_range=',
    'request_to_last_us=', 'first_to_last_us=', 'crc_errors=',
    'bad_lengths=', 'noise_bytes=', 'stat_runtime_excluded=',
    'request_enqueue_us=', 'request_tx_complete_us=',
    'request_tx_duration_us=', 'post_list_heartbeat_us=',
    'list_complete_to_post_heartbeat_us=',
    'data_result=', 'heartbeat_result=', 'target_10s_data_result=',
    'target_30s_data_result=', 'target_10s_result=',
    'target_30s_result=', 'write_semantics=', 'crc_scope='
  )) {
  Require-Pattern ([regex]::Escape($field)) "machine-readable $field output"
}
Require-Pattern 'START\s+<nonce>' 'explicit nonce-bound start command'
Require-Pattern 'heartbeat_count\s*<\s*2U' `
  'heartbeat readiness gate before request'
Require-Pattern 'run_heartbeat_count\s*>=\s*2U' `
  'minimum in-run HEARTBEAT acceptance count'
Require-Pattern 'request_write_count\s*==\s*1U' `
  'exactly one request write in strict data predicate'
Require-Pattern 'heartbeat_max_gap_us\s*<=\s*kHeartbeatMaximumGapUs' `
  'HEARTBEAT maximum-gap acceptance predicate'
Require-Pattern '(?:parser_totals\.noise_bytes\s*==\s*run\.parser_noise_baseline|noise_bytes\s*==\s*0U)' `
  'zero-noise strict data predicate'
Require-Pattern 'crc_scope=heartbeat_and_param_value_only' `
  'honest limited CRC-validation scope'
Require-Pattern 'target_10s_data_pass\s*=\s*[\s\S]{0,160}data_pass[\s\S]{0,300}request_to_last_us\s*<=\s*kTarget10SecondsUs' `
  'ten-second target evaluated independently on strict data'
Require-Pattern 'target_30s_data_pass\s*=\s*[\s\S]{0,160}data_pass[\s\S]{0,300}request_to_last_us\s*<=\s*kTarget30SecondsUs' `
  'thirty-second target evaluated independently on strict data'

$parameterHandlerMatch = [regex]::Match(
  $text,
  'void\s+handle_parameter_value\s*\([\s\S]*?(?=\r?\nvoid\s+handle_complete_frame\s*\()')
if (-not $parameterHandlerMatch.Success) {
  throw 'FW-PIXHAWK-D7-PARAM-BENCH-001: missing parameter handler body'
}
$parameterHandler = $parameterHandlerMatch.Value
Require-InText $parameterHandler `
  'unique\s*==\s*kExpectedParameterCount[\s\S]{0,180}awaiting_post_list_heartbeat\s*=\s*true[\s\S]{0,120}list_complete_us\s*=\s*observed_us' `
  'list-complete transition into post-HEARTBEAT wait'
Reject-InText $parameterHandler 'print_terminal_result\s*\(' `
  'immediate terminal result from PARAM_VALUE handler'

$heartbeatHandlerMatch = [regex]::Match(
  $text,
  'void\s+handle_primary_heartbeat\s*\([\s\S]*?(?=\r?\nvoid\s+handle_parameter_value\s*\()')
if (-not $heartbeatHandlerMatch.Success) {
  throw 'FW-PIXHAWK-D7-PARAM-BENCH-001: missing HEARTBEAT handler body'
}
$heartbeatHandler = $heartbeatHandlerMatch.Value
Require-InText $heartbeatHandler `
  'awaiting_post_list_heartbeat[\s\S]{0,180}observed_us\s*>=\s*run\.list_complete_us[\s\S]{0,180}post_list_heartbeat_us\s*=\s*observed_us[\s\S]{0,180}print_terminal_result\s*\(\s*"post_list_heartbeat"\s*\)' `
  'post-list HEARTBEAT as the only successful terminal trigger'
Reject-Pattern 'PARAM_REQUEST_READ' 'per-index retry traffic'
Reject-Pattern 'PARAM_SET' 'parameter mutation support'
Reject-Pattern 'COMMAND_LONG' 'vehicle command support'
Reject-Pattern 'E220|LoRa|M0_PIN|M1_PIN' 'radio dependency in D7 isolation test'

Write-Output 'FW-PIXHAWK-D7-PARAM-BENCH-001 PASS'
