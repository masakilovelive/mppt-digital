$script:R19CandidateArtifactSchema =
  'vc-lora-r19-candidate-artifact-manifest-v1'
$script:R19CandidateHandoffSchema =
  'vc-lora-r19-candidate-artifact-handoff-v1'
$script:R19CandidateLatestSchema =
  'vc-lora-r19-candidate-artifact-latest-v1'
$script:R19CandidateSealSchema = 'vc-lora-r19-candidate-final-seal-v1'
$script:R19CandidateArtifactInventorySchema =
  'vc-lora-r19-candidate-artifact-inventory-v1'
$script:R19CandidateTestId = 'FW-R19-CANDIDATE-ARTIFACT-BUILD-001'
$script:R19CandidateHwcdcSemanticChecks = @(
  'diagnostic_bootstrap_api_macro_scoped',
  'diagnostic_bootstrap_exact_63_byte_cold_start_only',
  'diagnostic_bootstrap_requires_clean_empty_boundary',
  'diagnostic_bootstrap_all_or_zero_publication_fence',
  'diagnostic_bootstrap_payload_primes_fifo_before_flush',
  'diagnostic_bootstrap_publishes_before_in_empty_enable',
  'diagnostic_bootstrap_rechecks_epoch_reset_and_presence',
  'diagnostic_bootstrap_isr_fence_before_ring_and_fifo',
  'diagnostic_bootstrap_serializes_debug_writer',
  'diagnostic_connected_requires_payload_pickup_witness',
  'diagnostic_flush_requires_payload_pickup_completion',
  'diagnostic_fifo_record_macro_scoped',
  'diagnostic_fifo_record_fixed_abi',
  'diagnostic_fifo_record_tracks_fifo_write_and_wr_done',
  'diagnostic_fifo_record_distinguishes_raw_in_empty_from_payload_pickup',
  'diagnostic_fifo_record_tracks_generation_reset_and_flush_outcome',
  'diagnostic_fifo_record_tracks_per_attempt_zlp_origins',
  'diagnostic_zlp_wr_done_origin_is_one_seqlock_transaction',
  'diagnostic_zlp_hardware_boundary_is_fail_closed',
  'diagnostic_zlp_invalid_post_state_is_fail_closed',
  'diagnostic_payload_wr_done_hardware_boundary_is_fail_closed',
  'diagnostic_fifo_write_hardware_boundary_is_fail_closed',
  'diagnostic_in_empty_side_effect_boundary_is_fail_closed',
  'diagnostic_bus_reset_and_raw_in_empty_boundary_is_fail_closed',
  'diagnostic_payload_causal_accounting_is_fail_closed',
  'diagnostic_flush_lifecycle_invalid_transition_is_fail_closed',
  'diagnostic_observation_window_matches_isr_lifecycle',
  'diagnostic_payload_publish_pending_closes_fifo_to_wrdone_gap',
  'diagnostic_payload_publish_abort_dominates_historical_success',
  'diagnostic_payload_flush_pending_binds_publication_to_new_flush_success',
  'in_empty_pickup_rechecks_bus_reset_under_mux',
  'late_pickup_reset_uses_raw_only_reset_discard',
  'postwrite_reset_quarantine_requires_positive_fifo_write',
  'zero_fifo_write_does_not_publish_payload'
)
$script:R19CandidateReproducibilityArtifactNames = @(
  'application.elf',
  'application.map',
  'build.options.json',
  'sdkconfig',
  'partitions.csv',
  'flash_args'
)
$script:R19CandidateHeaderNames = @(
  'e220_high_speed_transport_model.hpp',
  'high_speed_phase6_adapter.hpp',
  'phase6_bulk_rx_tail_ledger.hpp',
  'phase6_high_speed_radio_session.hpp',
  'phase6_high_speed_role_config.hpp',
  'phase6_radio_writer_arbiter.hpp',
  'peer_completion_receipt.hpp',
  'r19_runtime_fail_diagnostic.hpp',
  'r19_runtime_stage_record.hpp',
  'r19_first_usb_failure_record.hpp',
  'r19_usb_clock_sync.hpp',
  'terminal_ack_bridge.hpp',
  'terminal_ack_producer.hpp',
  'terminal_ack_wire.hpp',
  'vc_lora_high_speed_candidate.hpp'
)
$script:R19CandidateRoles = @(
  [pscustomobject][ordered]@{
    role = 'vehicle'
    name = 'Vehicle'
    sketch = 'vc_lora_vehicle_xiao_esp32s3'
    role_macro = 'VC_LORA_PHASE6_VEHICLE=1'
  },
  [pscustomobject][ordered]@{
    role = 'ground'
    name = 'Ground'
    sketch = 'vc_lora_ground_xiao_esp32s3'
    role_macro = 'VC_LORA_PHASE6_GROUND=1'
  }
)

function Get-R19CandidateOutputLeaf([bool]$RuntimeFailDiagnostics,[string]$TimedPathMode='Disabled') {
  if($TimedPathMode -cnotin @('Disabled','SyncOnly','ExplicitHostArm')){throw 'Unknown timed path mode'}
  if($TimedPathMode-cne'Disabled'){
    if(-not$RuntimeFailDiagnostics){throw 'Timed path mode requires RuntimeFailDiagnostics'}
    if($TimedPathMode-ceq'SyncOnly'){return 'R19-TIMED-PATH-SYNC-ONLY-DIAGNOSTIC-CANDIDATE-BUILD-001'}
    return 'R19-TIMED-PATH-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001'
  }
  if($RuntimeFailDiagnostics){return 'R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001'}
  return 'R19-HS-PRODUCT-CANDIDATE-BUILD-001'
}

function Get-R19TimedPathCandidateContract([string]$RepoRoot,[string]$Mode) {
  if($Mode-ceq'Disabled'){return $null}
  if($Mode-cnotin@('SyncOnly','ExplicitHostArm')){throw 'Unknown timed path mode'}
  return [pscustomobject][ordered]@{
    schema='vc-lora-r19-timed-path-candidate-v1';enabled=$true;mode=$Mode
    mode_value=$(if($Mode-ceq'SyncOnly'){1}else{2});macro='VC_LORA_R19_TIMED_PATH_DIAGNOSTICS'
    reader_schema='vc-lora-r19-runtime-stage-jtag-read-v6'
    record=[pscustomobject][ordered]@{symbol='vc_lora_r19_timed_path_record';schema_version=1;size_bytes=512}
    decoder=[pscustomobject][ordered]@{path='tools/read_r19_timed_path_record.ps1';sha256=Get-R19Sha256 (Join-Path $RepoRoot 'tools/read_r19_timed_path_record.ps1')}
  }
}

function Get-R19CandidateCompileProperty([bool]$RuntimeFailDiagnostics,[string]$TimedPathMode='Disabled') {
  [void](Get-R19CandidateOutputLeaf $RuntimeFailDiagnostics $TimedPathMode)
  $flags='compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1'
  if($RuntimeFailDiagnostics){$flags+=' -DVC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1'}
  if($TimedPathMode-cne'Disabled'){
    $modeValue=if($TimedPathMode-ceq'SyncOnly'){1}else{2}
    $flags+=" -DVC_LORA_R19_TIMED_PATH_DIAGNOSTICS=1 -DVC_LORA_R19_USB_READINESS_MODE=$modeValue"
  }
  return $flags
}

function Get-R19DiagnosticExtensionContract([bool]$RequireFirstFailure = $false) {
  $contract = [pscustomobject][ordered]@{
    schema = $(if ($RequireFirstFailure) {
      'vc-lora-r19-usb-extended-diagnostics-v2'
    } else { 'vc-lora-r19-usb-extended-diagnostics-v1' })
    enabled = $true
    records = [pscustomobject][ordered]@{
      hwcdc_restart = [pscustomobject][ordered]@{
        symbol = 'vc_lora_r19_hwcdc_restart_diagnostic_record'
        schema_version = 1
        size_bytes = 128
      }
      ground_usb_commit = [pscustomobject][ordered]@{
        symbol = 'vc_lora_r19_ground_usb_commit_record'
        schema_version = 1
        size_bytes = 128
      }
    }
  }
  if ($RequireFirstFailure) {
    Add-Member -InputObject $contract.records -NotePropertyName 'first_usb_failure' `
      -NotePropertyValue ([pscustomobject][ordered]@{
        symbol = 'vc_lora_r19_first_usb_failure_record'
        schema_version = 1
        size_bytes = 384
      })
  }
  return $contract
}

function Get-R19FirstFailureDecoderBinding([string]$RepoRoot) {
  $relative = 'tools/read_r19_first_usb_failure_record.ps1'
  return [pscustomobject][ordered]@{
    path = $relative
    sha256 = Get-R19Sha256 (Join-Path $RepoRoot $relative.Replace('/', '\'))
  }
}

function Get-R19ElfDiagnosticSymbols([string]$ElfPath,
    [bool]$RequireExtensions = $true,
    [bool]$RequireFirstFailure = $false,[bool]$RequireTimedPath=$false) {
  if($RequireTimedPath-and-not$RequireFirstFailure){throw 'Timed path requires first failure and extension ABI'}
  if ($RequireFirstFailure -and -not $RequireExtensions) {
    throw 'Diagnostic first-failure symbol requires the full extension contract'
  }
  # Parse the sealed ELF itself rather than trusting map text or caller-supplied
  # addresses. The independent live reader also checks these addresses with nm.
  [byte[]]$bytes = [IO.File]::ReadAllBytes($ElfPath)
  if ($bytes.Length -lt 52 -or $bytes[0] -ne 0x7F -or
      $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46 -or
      $bytes[4] -ne 1 -or $bytes[5] -ne 1 -or $bytes[6] -ne 1 -or
      [BitConverter]::ToUInt16($bytes, 16) -ne 2 -or
      [BitConverter]::ToUInt16($bytes, 18) -ne 94 -or
      [BitConverter]::ToUInt32($bytes, 20) -ne 1) {
    throw 'Diagnostic symbols require an ELF32 little-endian Xtensa executable'
  }
  [uint64]$sectionOffset = [BitConverter]::ToUInt32($bytes, 32)
  [uint32]$sectionEntrySize = [BitConverter]::ToUInt16($bytes, 46)
  [uint32]$sectionCount = [BitConverter]::ToUInt16($bytes, 48)
  if ($sectionEntrySize -ne 40 -or $sectionCount -eq 0 -or
      ($sectionOffset + [uint64]$sectionCount * 40) -gt $bytes.Length) {
    throw 'Diagnostic ELF section table is invalid or truncated'
  }
  $definitions = [ordered]@{
    runtime_stage = @('vc_lora_r19_runtime_stage_record', 68)
    endpoint_fifo = @('vc_lora_r19_hwcdc_fifo_diagnostic_record', 112)
    hwcdc_restart = @('vc_lora_r19_hwcdc_restart_diagnostic_record', 128)
    ground_usb_commit = @('vc_lora_r19_ground_usb_commit_record', 128)
    first_usb_failure = @('vc_lora_r19_first_usb_failure_record', 384)
    timed_path = @('vc_lora_r19_timed_path_record', 512)
  }
  $keysByName = [Collections.Generic.Dictionary[string,string]]::new(
    [StringComparer]::Ordinal)
  foreach ($key in $definitions.Keys) {
    $keysByName.Add([string]$definitions[$key][0], [string]$key)
  }
  $found = @{}
  $symbolTables = 0
  for ($sectionIndex = 0; $sectionIndex -lt $sectionCount; $sectionIndex++) {
    [int]$section = [int]($sectionOffset + $sectionIndex * 40)
    if ([BitConverter]::ToUInt32($bytes, $section + 4) -ne 2) { continue }
    $symbolTables++
    [uint64]$tableOffset = [BitConverter]::ToUInt32($bytes, $section + 16)
    [uint64]$tableSize = [BitConverter]::ToUInt32($bytes, $section + 20)
    [uint32]$stringIndex = [BitConverter]::ToUInt32($bytes, $section + 24)
    [uint32]$entrySize = [BitConverter]::ToUInt32($bytes, $section + 36)
    if ($entrySize -ne 16 -or ($tableSize % 16) -ne 0 -or
        ($tableOffset + $tableSize) -gt $bytes.Length -or
        $stringIndex -ge $sectionCount) {
      throw 'Diagnostic ELF symbol table is invalid or truncated'
    }
    [int]$stringSection = [int]($sectionOffset + $stringIndex * 40)
    [uint64]$stringOffset = [BitConverter]::ToUInt32($bytes, $stringSection + 16)
    [uint64]$stringSize = [BitConverter]::ToUInt32($bytes, $stringSection + 20)
    if ([BitConverter]::ToUInt32($bytes, $stringSection + 4) -ne 3 -or
        ($stringOffset + $stringSize) -gt $bytes.Length) {
      throw 'Diagnostic ELF symbol-name table is invalid or truncated'
    }
    for ([uint64]$position = 0; $position -lt $tableSize; $position += 16) {
      [int]$entry = [int]($tableOffset + $position)
      [uint32]$nameOffset = [BitConverter]::ToUInt32($bytes, $entry)
      if ($nameOffset -ge $stringSize) {
        throw 'Diagnostic ELF symbol-name offset is outside its string table'
      }
      [int]$nameStart = [int]($stringOffset + $nameOffset)
      [int]$nameEnd = $nameStart
      while ($nameEnd -lt ($stringOffset + $stringSize) -and
          $bytes[$nameEnd] -ne 0) { $nameEnd++ }
      if ($nameEnd -eq ($stringOffset + $stringSize)) {
        throw 'Diagnostic ELF symbol name is unterminated'
      }
      $name = [Text.Encoding]::ASCII.GetString(
        $bytes, $nameStart, $nameEnd - $nameStart)
      if (-not $keysByName.ContainsKey($name)) { continue }
      $key = $keysByName[$name]
      if ($found.ContainsKey($key)) {
        throw "Diagnostic symbol is ambiguous in the sealed ELF: $name"
      }
      [uint32]$address = [BitConverter]::ToUInt32($bytes, $entry + 4)
      [uint32]$size = [BitConverter]::ToUInt32($bytes, $entry + 8)
      [uint32]$owner = [BitConverter]::ToUInt16($bytes, $entry + 14)
      if (($bytes[$entry + 12] -band 15) -ne 1 -or
          $owner -eq 0 -or $owner -ge $sectionCount) {
        throw "Diagnostic symbol is not a defined object in the sealed ELF: $name"
      }
      [int]$ownerSection = [int]($sectionOffset + $owner * 40)
      [uint32]$ownerType = [BitConverter]::ToUInt32($bytes, $ownerSection + 4)
      [uint32]$ownerFlags = [BitConverter]::ToUInt32($bytes, $ownerSection + 8)
      [uint64]$ownerStart = [BitConverter]::ToUInt32($bytes, $ownerSection + 12)
      [uint64]$ownerSize = [BitConverter]::ToUInt32($bytes, $ownerSection + 20)
      [uint64]$end = [uint64]$address + $size
      if ($ownerType -ne 8 -or ($ownerFlags -band 3) -ne 3 -or
          $address -lt $ownerStart -or $end -gt ($ownerStart + $ownerSize) -or
          $end -gt [uint64]4294967296) {
        throw "Diagnostic symbol is not contained in allocated writable BSS: $name"
      }
      if ($size -ne [uint32]$definitions[$key][1]) {
        throw "Diagnostic symbol size is not exact in the sealed ELF: $name"
      }
      if (($address -band 3) -ne 0) {
        throw "Diagnostic symbol address is not 32-bit aligned: $name"
      }
      $found[$key] = [pscustomobject][ordered]@{
        name = $name
        address = '0x{0:x8}' -f $address
        size_bytes = $size
        aligned_32_bit = $true
      }
    }
  }
  if ($symbolTables -ne 1) {
    throw 'Diagnostic ELF must contain exactly one static symbol table'
  }
  $result = [ordered]@{}
  foreach ($key in $definitions.Keys) {
    $required = $key -in @('runtime_stage', 'endpoint_fifo') -or
      ($RequireExtensions -and $key -in @('hwcdc_restart', 'ground_usb_commit')) -or
      ($RequireFirstFailure -and $key -ceq 'first_usb_failure') -or
      ($RequireTimedPath -and $key -ceq 'timed_path')
    if (-not $found.ContainsKey($key)) {
      if ($required) {
        throw "Diagnostic symbol is absent from the sealed ELF: $($definitions[$key][0])"
      }
      continue
    }
    if (-not $required) {
      throw 'Diagnostic ELF contains undeclared diagnostic extensions'
    }
    $result[$key] = $found[$key]
  }
  $ordered = @($result.Values)
  for ($left = 0; $left -lt $ordered.Count; $left++) {
    [uint64]$leftStart = ConvertTo-R19UnsignedInteger $ordered[$left].address 'symbol'
    for ($right = $left + 1; $right -lt $ordered.Count; $right++) {
      [uint64]$rightStart = ConvertTo-R19UnsignedInteger $ordered[$right].address 'symbol'
      if ($leftStart -lt ($rightStart + $ordered[$right].size_bytes) -and
          $rightStart -lt ($leftStart + $ordered[$left].size_bytes)) {
        throw 'Diagnostic symbols overlap in the sealed ELF'
      }
    }
  }
  return [pscustomobject]$result
}

function Get-R19DiagnosticSymbolBinding([string]$ElfPath,
    [string]$MapPath, [string]$ApplicationSha256,
    [bool]$RequireFirstFailure = $false,[bool]$RequireTimedPath=$false) {
  return [pscustomobject][ordered]@{
    schema = 'vc-lora-r19-runtime-diagnostic-symbols-v1'
    elf_sha256 = Get-R19Sha256 $ElfPath
    map_sha256 = Get-R19Sha256 $MapPath
    application_sha256 = $ApplicationSha256
    symbols = Get-R19ElfDiagnosticSymbols $ElfPath $true $RequireFirstFailure $RequireTimedPath
  }
}

function Get-R19Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
    ToUpperInvariant()
}

function ConvertTo-R19UnsignedInteger([string]$Text,
                                      [string]$Description) {
  $value = $Text.Trim().Trim('"', "'")
  [uint64]$parsed = 0
  if ($value -cmatch '^0[xX]([0-9A-Fa-f]+)$') {
    if (-not [uint64]::TryParse($Matches[1],
        [Globalization.NumberStyles]::AllowHexSpecifier,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
      throw "$Description is outside the supported integer range: $Text"
    }
    return $parsed
  }
  if (-not [uint64]::TryParse($value,
      [Globalization.NumberStyles]::None,
      [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    throw "$Description is not an unsigned integer: $Text"
  }
  return $parsed
}

function Get-R19ApplicationFlashLayout(
    [string]$RoleName, [string]$ApplicationFileName,
    [string]$FlashArgsPath, [string]$PartitionsCsvPath) {
  $expectedOffset = [uint64]0x10000
  $flashArgsFile = Get-Item -LiteralPath $FlashArgsPath -ErrorAction Stop
  $partitionsFile = Get-Item -LiteralPath $PartitionsCsvPath -ErrorAction Stop
  if ($flashArgsFile.PSIsContainer -or $partitionsFile.PSIsContainer) {
    throw "$RoleName flash layout inputs must be files"
  }

  $tokens = @([regex]::Matches(
      (Get-Content -LiteralPath $flashArgsFile.FullName -Raw),
      '(?:"(?:\\.|[^"])*"|''(?:\\.|[^''])*''|\S+)') |
    ForEach-Object { $_.Value.Trim().Trim('"', "'") })
  $applicationTokenIndices = [Collections.Generic.List[int]]::new()
  for ($index = 0; $index -lt $tokens.Count; $index++) {
    $tokenPath = [string]$tokens[$index]
    $tokenName = [IO.Path]::GetFileName($tokenPath.Replace('/', '\'))
    if ($tokenName.Equals(
        $ApplicationFileName, [StringComparison]::OrdinalIgnoreCase)) {
      $applicationTokenIndices.Add($index)
    }
  }
  if ($applicationTokenIndices.Count -ne 1) {
    throw ("$RoleName flash_args application occurrence count is not " +
      "exactly one: $($applicationTokenIndices.Count)")
  }
  $applicationIndex = $applicationTokenIndices[0]
  if ($applicationIndex -eq 0) {
    throw "$RoleName flash_args application has no preceding offset"
  }
  $flashOffset = ConvertTo-R19UnsignedInteger `
    ([string]$tokens[$applicationIndex - 1]) `
    "$RoleName flash_args application offset"
  if ($flashOffset -ne $expectedOffset) {
    throw ("$RoleName flash_args application offset is not 0x10000: " +
      ('0x{0:X}' -f $flashOffset))
  }

  $appRows = [Collections.Generic.List[object]]::new()
  foreach ($rawLine in @(Get-Content -LiteralPath $partitionsFile.FullName)) {
    $line = [string]$rawLine
    if ([string]::IsNullOrWhiteSpace($line) -or
        $line.TrimStart().StartsWith('#', [StringComparison]::Ordinal)) {
      continue
    }
    $row = $line | ConvertFrom-Csv -Header @(
      'name', 'type', 'subtype', 'offset', 'size', 'flags')
    if ([string]$row.type.Trim() -ieq 'app') {
      $offsetText = [string]$row.offset
      if ([string]::IsNullOrWhiteSpace($offsetText)) {
        throw "$RoleName partitions.csv contains an app row without offset"
      }
      $offset = ConvertTo-R19UnsignedInteger $offsetText `
        "$RoleName partitions.csv app offset"
      $size = ConvertTo-R19UnsignedInteger ([string]$row.size) `
        "$RoleName partitions.csv app size"
      $appRows.Add([pscustomobject][ordered]@{
        name = ([string]$row.name).Trim()
        subtype = ([string]$row.subtype).Trim()
        offset = $offset
        size = $size
      })
    }
  }
  if ($appRows.Count -eq 0) {
    throw "$RoleName partitions.csv contains no app region"
  }
  $targetRows = @($appRows | Where-Object {
      [uint64]$_.offset -eq $flashOffset
    })
  if ($targetRows.Count -ne 1) {
    $offsets = @($appRows | ForEach-Object {
        '0x{0:X}' -f [uint64]$_.offset
      }) -join ','
    throw ("$RoleName partitions.csv target app offset is not exactly " +
      "0x10000: app_offsets=$offsets")
  }
  $target = $targetRows[0]
  if ([uint64]$target.size -eq 0) {
    throw "$RoleName partitions.csv target app region has zero size"
  }

  return [pscustomobject][ordered]@{
    schema = 'vc-lora-r19-application-flash-layout-v1'
    application_file_name = $ApplicationFileName
    flash_args = [pscustomobject][ordered]@{
      sha256 = Get-R19Sha256 $flashArgsFile.FullName
      application_occurrences = $applicationTokenIndices.Count
      application_offset = '0x{0:X}' -f $flashOffset
    }
    partitions_csv = [pscustomobject][ordered]@{
      sha256 = Get-R19Sha256 $partitionsFile.FullName
      target_app_occurrences = $targetRows.Count
      target_app_name = [string]$target.name
      target_app_subtype = [string]$target.subtype
      target_app_offset = '0x{0:X}' -f [uint64]$target.offset
      target_app_size_bytes = [uint64]$target.size
    }
  }
}

function Resolve-R19RepositoryRoot([string]$RepoRoot) {
  return (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
}

function Assert-R19HwcdcSemanticSummary(
    [object]$Summary, [object]$HwcdcHashes, [string]$Fqbn,
    [string]$ExpectedCoreVersion) {
  if ($null -eq $Summary -or [int]$Summary.schema_version -ne 1 -or
      [string]$Summary.test -cne 'FW-HWCDC-TX-INTEGRITY-001' -or
      [string]$Summary.result -cne 'PASS') {
    throw 'HWCDC semantic summary identity or result is invalid'
  }
  if ([string]$Summary.fqbn -cne $Fqbn -or
      [string]$Summary.expected_core_version -cne $ExpectedCoreVersion -or
      [string]$Summary.actual_core_version -cne $ExpectedCoreVersion) {
    throw 'HWCDC semantic summary toolchain identity is invalid'
  }
  if ([string]$Summary.hwcdc_sha256 -cne
        [string]$HwcdcHashes.installed_cpp_sha256 -or
      [string]$Summary.hwcdc_header_sha256 -cne
        [string]$HwcdcHashes.installed_h_sha256 -or
      [string]$Summary.diagnostic_header_sha256 -cne
        [string]$HwcdcHashes.installed_diagnostic_h_sha256 -or
      [string]$Summary.canonical_hwcdc_sha256 -cne
        [string]$HwcdcHashes.canonical_cpp_sha256 -or
      [string]$Summary.canonical_hwcdc_header_sha256 -cne
        [string]$HwcdcHashes.canonical_h_sha256 -or
      [string]$Summary.canonical_diagnostic_header_sha256 -cne
        [string]$HwcdcHashes.canonical_diagnostic_h_sha256) {
    throw 'HWCDC semantic summary is not bound to the candidate inputs'
  }
  if ([IO.Path]::GetFullPath([string]$Summary.diagnostic_header_path) -cne
        [IO.Path]::GetFullPath(
          [string]$HwcdcHashes.installed_diagnostic_h_path) -or
      [IO.Path]::GetFullPath(
        [string]$Summary.canonical_diagnostic_header_path) -cne
        [IO.Path]::GetFullPath(
          [string]$HwcdcHashes.canonical_diagnostic_h_path)) {
    throw 'HWCDC semantic summary diagnostic-header path binding is invalid'
  }
  if (@($Summary.failures).Count -ne 0) {
    throw 'HWCDC semantic summary contains failures'
  }
  $checks = @($Summary.checks)
  if ($checks.Count -eq 0) {
    throw 'HWCDC semantic summary contains no named assertions'
  }
  $names = @($checks | ForEach-Object { [string]$_.name })
  if (@($names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne
      0 -or @($names | Sort-Object -Unique).Count -ne $names.Count) {
    throw 'HWCDC semantic summary has missing or duplicate assertion names'
  }
  foreach ($check in $checks) {
    if ($check.PSObject.Properties['valid'] -eq $null -or
        $check.valid -isnot [bool] -or -not [bool]$check.valid) {
      throw "HWCDC semantic assertion is not true: $($check.name)"
    }
  }
  foreach ($required in $script:R19CandidateHwcdcSemanticChecks) {
    if ($names -cnotcontains $required) {
      throw "HWCDC semantic summary lacks required assertion: $required"
    }
  }
  return $checks
}

function Assert-R19PathWithin([string]$Root, [string]$Path,
                              [string]$Description) {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar)
  $pathFull = [IO.Path]::GetFullPath($Path)
  $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  if (-not $pathFull.StartsWith(
      $prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Description escaped its required root: $pathFull"
  }
  return $pathFull
}

function Get-R19RelativePath([string]$Root, [string]$Path) {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar)
  $pathFull = Assert-R19PathWithin $rootFull $Path 'candidate artifact path'
  return $pathFull.Substring($rootFull.Length).TrimStart('\', '/').
    Replace('\', '/')
}

function Write-R19DurableBytes([string]$Path, [byte[]]$Bytes) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Durable artifact parent is missing: $parent"
  }
  $stream = [IO.FileStream]::new(
    $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
    [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
  try {
    $stream.Write($Bytes, 0, $Bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
}

function Write-R19DurableText([string]$Path, [string]$Text) {
  $utf8 = [Text.UTF8Encoding]::new($false)
  Write-R19DurableBytes $Path $utf8.GetBytes($Text)
}

function Write-R19DurableJson([string]$Path, [object]$Value) {
  Write-R19DurableText $Path (($Value | ConvertTo-Json -Depth 32) + "`n")
  [void](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Copy-R19DurableFile([string]$Source, [string]$Destination) {
  $bytes = [IO.File]::ReadAllBytes($Source)
  Write-R19DurableBytes $Destination $bytes
  if ((Get-R19Sha256 $Source) -cne (Get-R19Sha256 $Destination)) {
    throw "Durable copy SHA-256 mismatch: $Source"
  }
}

function New-R19FileRecord([string]$Root, [string]$Path) {
  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.PSIsContainer) {
    throw "Expected a file: $Path"
  }
  return [pscustomobject][ordered]@{
    path = Get-R19RelativePath $Root $file.FullName
    size_bytes = [int64]$file.Length
    sha256 = Get-R19Sha256 $file.FullName
  }
}

function Get-R19OrdinalPathRecords([object[]]$Records) {
  $ordered = [Collections.Generic.List[object]]::new()
  foreach ($record in @($Records)) {
    $ordered.Add($record)
  }
  $ordered.Sort([Comparison[object]]{
      param($left, $right)
      return [StringComparer]::OrdinalIgnoreCase.Compare(
        [string]$left.path, [string]$right.path)
    })
  return @($ordered.ToArray())
}

function Get-R19CanonicalTreeHash([object[]]$Records) {
  $ordinalRecords = @(Get-R19OrdinalPathRecords $Records)
  $lines = @($ordinalRecords | ForEach-Object {
      "$($_.sha256)  $($_.path)"
    })
  $canonical = ($lines -join "`n") + "`n"
  $utf8 = [Text.UTF8Encoding]::new($false)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return [BitConverter]::ToString(
      $sha.ComputeHash($utf8.GetBytes($canonical))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Get-R19TreeSnapshot([string]$Root, [string[]]$Paths) {
  $records = [Collections.Generic.List[object]]::new()
  foreach ($path in @($Paths)) {
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }
    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer) {
      foreach ($file in @(Get-ChildItem -LiteralPath $item.FullName -Recurse `
          -File | Sort-Object FullName)) {
        $records.Add((New-R19FileRecord $Root $file.FullName))
      }
    } else {
      $records.Add((New-R19FileRecord $Root $item.FullName))
    }
  }
  $ordered = @(Get-R19OrdinalPathRecords $records.ToArray())
  return [pscustomobject][ordered]@{
    file_count = $ordered.Count
    tree_sha256 = Get-R19CanonicalTreeHash $ordered
    records = $ordered
  }
}

function Assert-R19SameSnapshot([object]$Expected, [object]$Actual,
                                [string]$Description) {
  if ([int]$Expected.file_count -ne [int]$Actual.file_count -or
      [string]$Expected.tree_sha256 -cne [string]$Actual.tree_sha256) {
    throw "$Description changed while the candidate artifact was built"
  }
}

function Get-R19CandidateSourceFiles([string]$RepoRoot,[string]$TimedPathMode='Disabled') {
  $repo = Resolve-R19RepositoryRoot $RepoRoot
  $files = [Collections.Generic.List[IO.FileInfo]]::new()
  $files.AddRange([IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\src') -File -Filter '*.cpp'))
  $files.AddRange([IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\include\vc_lora') -File -Filter '*.hpp'))
  foreach ($relative in @(
      'firmware\phase6\vc_lora_phase6_bridge.hpp',
      'firmware\arduino_libraries\VC_LoRa_Core\src\VC_LoRa_Core.h',
      'tools\read_r19_first_usb_failure_record.ps1',
      'vc_lora_vehicle_xiao_esp32s3\vc_lora_vehicle_xiao_esp32s3.ino',
      'vc_lora_ground_xiao_esp32s3\vc_lora_ground_xiao_esp32s3.ino'
    )) {
    $files.Add((Get-Item -LiteralPath (Join-Path $repo $relative) `
        -ErrorAction Stop))
  }

  $candidateRoot = Join-Path $repo 'firmware\high_speed'
  $actualNames = @(Get-ChildItem -LiteralPath $candidateRoot -File `
    -Filter '*.hpp' | ForEach-Object { $_.Name } | Sort-Object)
  $extraHeaders=@('r19_timed_path_record.hpp')
  $expectedNames = @(@($script:R19CandidateHeaderNames)+@($extraHeaders|Where-Object{Test-Path (Join-Path $candidateRoot $_)}) | Sort-Object)
  if (@(Compare-Object -ReferenceObject $expectedNames `
      -DifferenceObject $actualNames).Count -ne 0) {
    throw 'Canonical R19 candidate package is not the exact header allowlist'
  }
  foreach ($name in $script:R19CandidateHeaderNames) {
    $files.Add((Get-Item -LiteralPath (Join-Path $candidateRoot $name) `
        -ErrorAction Stop))
  }
  if($TimedPathMode-cne'Disabled'){
    foreach($relative in @('firmware/high_speed/r19_timed_path_record.hpp','firmware/diagnostics/r19_host_readiness.hpp','tools/read_r19_timed_path_record.ps1')){
      $files.Add((Get-Item -LiteralPath (Join-Path $repo $relative) -ErrorAction Stop))
    }
  }

  $unique = @{}
  foreach ($file in $files) {
    $relative = Get-R19RelativePath $repo $file.FullName
    $key = $relative.ToUpperInvariant()
    if ($unique.ContainsKey($key)) {
      throw "Duplicate candidate source path: $relative"
    }
    $unique[$key] = $file
  }
  return @($unique.Values | Sort-Object FullName)
}

function Get-R19CandidateSourceSnapshot([string]$RepoRoot,[string]$TimedPathMode='Disabled') {
  $repo = Resolve-R19RepositoryRoot $RepoRoot
  $sourceRecords = @(Get-R19CandidateSourceFiles $repo $TimedPathMode | ForEach-Object {
      New-R19FileRecord $repo $_.FullName
    })
  $records = @(Get-R19OrdinalPathRecords $sourceRecords)
  return [pscustomobject][ordered]@{
    file_count = $records.Count
    tree_sha256 = Get-R19CanonicalTreeHash $records
    records = $records
  }
}

function Read-R19HashFile([string]$Path, [string]$ExpectedFileName) {
  $text = (Get-Content -LiteralPath $Path -Raw).Trim()
  $pattern = '^([0-9A-F]{64}) \*' + [regex]::Escape($ExpectedFileName) + '$'
  if ($text -cnotmatch $pattern) {
    throw "Malformed SHA-256 file: $Path"
  }
  return $Matches[1]
}
