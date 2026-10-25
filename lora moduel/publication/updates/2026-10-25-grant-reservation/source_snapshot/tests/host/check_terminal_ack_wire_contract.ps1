param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$OutputDir = (Join-Path $RepoRoot `
      'runs\high_speed\HS-TERMINAL-ACK-CODEC-001\LATEST'),
  [string]$SanitizerCompiler = ''
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepoRoot)
$output = [IO.Path]::GetFullPath($OutputDir)
$repoPrefix = $repo.TrimEnd('\') + '\'
if (-not $output.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "output directory escaped repository: $output"
}
New-Item -ItemType Directory -Path $output -Force | Out-Null

$headerPath = Join-Path $repo 'firmware\high_speed\terminal_ack_wire.hpp'
$testPath = Join-Path $repo `
  'tests\host\standalone\terminal_ack_wire_tests.cpp'
$redPath = Join-Path $repo `
  'runs\high_speed\HS-TERMINAL-ACK-CODEC-001\test-first-red.txt'
$vehicleSketch = Join-Path $repo `
  'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino'
$groundSketch = Join-Path $repo `
  'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'
$demuxHeaderPath = Join-Path $repo `
  'core\include\vc_lora\tdd_link_demux.hpp'
$demuxSourcePath = Join-Path $repo 'core\src\tdd_link_demux.cpp'

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
  $checks.Add([pscustomobject]@{
      name = $Name
      passed = $Passed
      detail = $Detail
    })
}

function Get-FileEvidence([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $item = Get-Item -LiteralPath $Path
  return [pscustomobject]@{
    path = $item.FullName.Substring($repoPrefix.Length).Replace('\', '/')
    bytes = [uint64]$item.Length
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
  }
}

$headerExists = Test-Path -LiteralPath $headerPath -PathType Leaf
$testExists = Test-Path -LiteralPath $testPath -PathType Leaf
$redExists = Test-Path -LiteralPath $redPath -PathType Leaf
Add-Check 'experimental_header_exists' $headerExists `
  'The codec is isolated under firmware/high_speed.'
Add-Check 'standalone_test_exists' $testExists `
  'The host-only negative matrix exists.'
Add-Check 'test_first_red_evidence_exists' $redExists `
  'The original missing-header strict compile exit=1 is preserved.'

$header = if ($headerExists) { Get-Content -Raw -LiteralPath $headerPath } `
  else { '' }
$tests = if ($testExists) { Get-Content -Raw -LiteralPath $testPath } `
  else { '' }
$demuxHeader = if (Test-Path -LiteralPath $demuxHeaderPath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $demuxHeaderPath
} else { '' }
$demuxSource = if (Test-Path -LiteralPath $demuxSourcePath -PathType Leaf) {
  Get-Content -Raw -LiteralPath $demuxSourcePath
} else { '' }

Add-Check 'exact_vcta_v1_fragment_schema' `
  ($header -match 'ASCII "VCTA"' -and
   $header -match 'fragment_bytes\s*=\s*32U' -and
   $header -match 'fragment_payload_bytes\s*=\s*18U' -and
   $header -match 'record_bytes\s*=\s*144U' -and
   $header -match 'fragment_count\s*==\s*8U' -and
   $header -match 'required_flags\s*=\s*0U') `
  'VCTA v1 is 8 exact 32-byte fragments carrying one fixed 144-byte record.'

Add-Check 'explicit_little_endian_and_two_level_integrity' `
  ($header -match 'put_u16' -and $header -match 'put_u32' -and
   $header -match 'put_u64' -and $header -match 'get_u16' -and
   $header -match 'get_u32' -and $header -match 'get_u64' -and
   $header -match 'crc16_ccitt_false' -and
   $header -match 'crc32c' -and
   $tests -match '0x29B1U' -and $tests -match '0xE3069283U') `
  'Integer encoding is explicit LE; CRC-16 and CRC-32C use reference vectors.'

Add-Check 'complete_pointer_free_value_record' `
  ($header -match 'record_id' -and $header -match 'session_id' -and
   $header -match 'stream_id' -and $header -match 'lease_id' -and
   $header -match 'ground_request_nonce' -and
   $header -match 'vehicle_terminal_challenge_nonce' -and
   $header -match 'final_parameter_count' -and
   $header -match 'final_global_chunk_ordinal' -and
   $header -match 'raw_mavlink_bytes' -and
   $header -match 'wire_chunk_count' -and
   $header -match 'wire_bytes' -and
   $header -match 'request_to_last_parameter_elapsed_ms' -and
   $header -match 'heartbeat_count' -and
   $header -match 'last_heartbeat_request_id' -and
   $header -match 'first_heartbeat_gap_ms' -and
   $header -match 'max_heartbeat_gap_ms' -and
   $header -match 'post_heartbeat_gap_ms' -and
   $header -match 'receiver_batch' -and
   $header -match 'receiver_revision' -and
   $header -match 'transcript_digest' -and
   $header -notmatch 'std::vector|std::unique_ptr|std::shared_ptr|malloc|calloc|realloc') `
  'The schema and reassembler use bounded value storage and no dynamic allocation.'

Add-Check 'fixed_932_and_sla_acceptance_contract' `
  ($header -match 'parameter-only terminal evidence' -and
   $header -match 'interleaved transfer-global fragment ordinal' -and
   $header -match 'required_parameter_count\s*=\s*932U' -and
   $header -match 'required_final_global_chunk_ordinal\s*=\s*1863U' -and
   $header -match 'required_raw_mavlink_bytes\s*=\s*34484U' -and
   $header -match 'required_wire_chunk_count\s*=\s*1864U' -and
   $header -match 'required_wire_bytes\s*=\s*59648U' -and
   $header -match 'parameter_deadline_ms\s*=\s*30000U' -and
   $header -match 'heartbeat_deadline_ms\s*=\s*2500U') `
  'The success-only v1 record cannot relax the accepted 932/30-second/HB SLA.'

Add-Check 'expected_tuple_and_one_shot_consumption' `
  ($header -match 'TerminalAckExpectedEvidence' -and
   $header -match 'TranscriptDigestMismatch' -and
   $header -match 'ReceiverBatchMismatch' -and
   $header -match 'ReceiverRevisionMismatch' -and
   $header -match 'take_record' -and $header -match 'consumed_' -and
   $header -match 'AlreadyConsumed' -and
   $header -match 'TerminalAckReassembler\(const TerminalAckReassembler&\) = delete' -and
   $tests -match '!std::is_copy_constructible_v<TerminalAckReassembler>' -and
   $header -notmatch 'copy_record|reset_for_next') `
  'Identity, accounting, SLA, batch/revision, and digest are exact; proof extraction is one-shot.'

Add-Check 'fail_closed_negative_matrix_present' `
  ($tests -match 'test_fragment_crc_covers_every_routed_header_and_payload_bit' -and
   $tests -match 'test_whole_record_crc_rejects_crc16_repaired_bit_flip' -and
   $tests -match 'test_missing_duplicate_reorder_and_mixed_fail_closed' -and
   $tests -match 'test_semantic_header_errors_require_valid_crc' -and
   $tests -match 'test_record_tag_and_body_id_are_both_bound' -and
   $tests -match 'test_colliding_record_tags_cannot_mix_records' -and
   $tests -match 'test_terminal_window_close_requires_explicit_finish' -and
   $tests -match 'test_wrong_identity_components_are_distinct_failures' -and
   $tests -match 'test_expected_evidence_exact_match_and_deadline_boundaries' -and
   $tests -match 'test_stale_replay_and_one_shot_challenge' -and
   $tests -match 'test_invalid_expectation_and_encoder_overflow_fail_closed') `
  'Corruption, truncation, order, mixing, identity, replay, overflow, and SLA boundaries are executable.'

Add-Check 'digest_domain_and_integration_blockers_are_explicit' `
  ($header -match 'VC-PARAM-HB-TRANSCRIPT' -and
   $header -match 'keyed MAC' -and
   $header -match 'IMPORTANT INTEGRATION BLOCKER' -and
   $header -match 'TddLinkDemux separates exact raw VCTD and VCTA' -and
   $header -match 'phase6 consumer' -and
   $header -match 'TerminalAckReassembler' -and
   $header -match 'raw_fragment_airtime_lower_bound_ms' -and
   $header -match 'require 512 bytes' -and
   $header -match 'remain unmeasured') `
  'Digest canonicalization, non-authentication, remaining consumer integration, and airtime uncertainty are not hidden.'

Add-Check 'production_vcta_demux_route_present' `
  ($demuxHeader -match 'has_terminal_ack' -and
   $demuxHeader -match 'terminal_ack_fragment' -and
   $demuxSource -match 'kTerminalAckMagic' -and
   $demuxSource -match 'event\.has_terminal_ack\s*=\s*true') `
  'Production demux separates exact raw VCTA fragments for a future fail-closed consumer.'

$forbidden = 'HardwareSerial|digitalWrite|pinMode|Serial\.|COM[0-9]|esptool|write_e220_profile|\b0xC0U\b|\b0xC2U\b'
Add-Check 'no_device_profile_or_flash_io' ($header -notmatch $forbidden) `
  'The codec contains no Arduino, E220 profile-write, COM, or flash operation.'

$productionReference = $false
foreach ($path in @($vehicleSketch, $groundSketch)) {
  if ((Get-Content -Raw -LiteralPath $path) -match 'terminal_ack_wire|VCTA') {
    $productionReference = $true
  }
}
Add-Check 'accepted_product_sketches_do_not_select_codec' `
  (-not $productionReference) `
  'R18 Ground/Vehicle entry points remain disconnected from the experiment.'

$compiler = Get-Command clang++ -ErrorAction SilentlyContinue
if (-not $compiler) {
  $fallback = Join-Path $env:TEMP `
    'vc_lora_host_tools\llvm-mingw-20260616-tar\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
  if (Test-Path -LiteralPath $fallback -PathType Leaf) {
    $compiler = Get-Item -LiteralPath $fallback
  }
}
$strictOutput = @()
$strictExit = $null
if ($compiler -and $testExists) {
  $compilerPath = if ($compiler.Source) { $compiler.Source } else {
    $compiler.FullName
  }
  $exe = Join-Path $output 'terminal_ack_wire_tests.exe'
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $strictOutput = @(& $compilerPath '-std=c++17' '-Wall' '-Wextra' `
        '-Wpedantic' '-Wconversion' '-Werror' $testPath '-o' $exe 2>&1)
    $strictExit = $LASTEXITCODE
    if ($strictExit -eq 0) {
      $strictOutput += @(& $exe 2>&1)
      $strictExit = $LASTEXITCODE
    }
  }
  finally { $ErrorActionPreference = $saved }
}
Add-Check 'strict_compile_and_runtime_pass' ($strictExit -eq 0) `
  "clang++ strict compile/runtime exit=$strictExit"

if (-not $SanitizerCompiler) {
  $autoSanitizer = Join-Path $env:TEMP `
    'vc_lora_host_tools\llvm-mingw-20260616-complete\unpacked\llvm-mingw-20260616-ucrt-x86_64\bin\clang++.exe'
  if (Test-Path -LiteralPath $autoSanitizer -PathType Leaf) {
    $SanitizerCompiler = $autoSanitizer
  }
}
$sanitizerOutput = @()
$sanitizerExit = $null
$sanitizerRuntime = $null
if ($SanitizerCompiler -and $testExists) {
  $sanitizerCompilerPath = [IO.Path]::GetFullPath($SanitizerCompiler)
  $sanitizerRuntime = Join-Path (Split-Path -Parent $sanitizerCompilerPath) `
    'libclang_rt.asan_dynamic-x86_64.dll'
  if ((Test-Path -LiteralPath $sanitizerCompilerPath -PathType Leaf) -and
      (Test-Path -LiteralPath $sanitizerRuntime -PathType Leaf)) {
    $exe = Join-Path $output 'terminal_ack_wire_tests_sanitize.exe'
    $savedPath = $env:PATH
    $savedAsan = $env:ASAN_OPTIONS
    $savedUbsan = $env:UBSAN_OPTIONS
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $compilerDir = Split-Path -Parent $sanitizerCompilerPath
      $env:PATH = "$compilerDir;$savedPath"
      $env:ASAN_OPTIONS = 'detect_leaks=0:halt_on_error=1'
      $env:UBSAN_OPTIONS = 'halt_on_error=1:print_stacktrace=1'
      $sanitizerOutput = @(& $sanitizerCompilerPath '-std=c++17' '-Wall' `
          '-Wextra' '-Wpedantic' '-Wconversion' '-Werror' `
          '-fsanitize=address,undefined' '-fno-omit-frame-pointer' `
          $testPath '-o' $exe 2>&1)
      $sanitizerExit = $LASTEXITCODE
      if ($sanitizerExit -eq 0) {
        $sanitizerOutput += @(& $exe 2>&1)
        $sanitizerExit = $LASTEXITCODE
      }
    }
    finally {
      $ErrorActionPreference = $saved
      $env:PATH = $savedPath
      $env:ASAN_OPTIONS = $savedAsan
      $env:UBSAN_OPTIONS = $savedUbsan
    }
  }
}
Add-Check 'asan_ubsan_compile_and_runtime_pass' ($sanitizerExit -eq 0) `
  "ASan+UBSan compile/runtime exit=$sanitizerExit"

$passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
$summary = [ordered]@{
  schema_version = 1
  test_id = 'HS-TERMINAL-ACK-CODEC-001'
  status = if ($passed) { 'PASS' } else { 'FAIL' }
  measurement_only = $true
  experimental_codec_only = $true
  product_integration_complete = $false
  live_gate = $false
  hardware_touched = $false
  com_opened = $false
  firmware_flashed = $false
  persistent_e220_registers_touched = $false
  metrics = [ordered]@{
    fragment_bytes = 32
    fragment_payload_bytes = 18
    fragment_count = 8
    canonical_record_bytes = 144
    raw_fragment_bytes = 256
    raw_payload_only_airtime_lower_bound_ms = 107
    candidate_uplink_window_ms = 150
    escaped_or_packetized_airtime_proven = $false
  }
  checks = @($checks)
  test_first = [ordered]@{
    red_observed = $redExists
    red_exit_code = 1
    green_exit_code = $strictExit
    sanitizer_exit_code = $sanitizerExit
  }
  inputs = @(
    Get-FileEvidence $PSCommandPath
    Get-FileEvidence $headerPath
    Get-FileEvidence $testPath
    Get-FileEvidence $redPath
    Get-FileEvidence $demuxHeaderPath
    Get-FileEvidence $demuxSourcePath
  ) | Where-Object { $_ -ne $null }
  strict_output = @($strictOutput | ForEach-Object { "$_" })
  sanitizer = [ordered]@{
    compiler = if ($SanitizerCompiler) {
      [IO.Path]::GetFullPath($SanitizerCompiler)
    } else { $null }
    runtime = $sanitizerRuntime
    exit_code = $sanitizerExit
    output = @($sanitizerOutput | ForEach-Object { "$_" })
  }
  integration_blockers = @(
    'phase6 has no fail-closed VCTA consumer or TerminalAckReassembler connection',
    'bulk stream identity/accounting and terminal evidence producers are not integrated',
    'escaped/packetized size and RF overhead are not bounded in live hardware',
    'terminal challenge, batch/revision, and digest producers are not integrated',
    'caller deadline/finish and challenge consumption are not integrated',
    '150 ms uplink window remains unproven',
    'accepted product entry points remain in standard mode'
  )
}

$summaryPath = Join-Path $output 'summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath `
  -Encoding UTF8
$summaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryPath).Hash
Set-Content -LiteralPath (Join-Path $output 'summary.sha256') `
  -Value "$summaryHash  summary.json" -Encoding ASCII

Write-Output "HS-TERMINAL-ACK-CODEC-001 $($summary.status)"
Write-Output "summary=$summaryPath"
if (-not $passed) { exit 1 }
