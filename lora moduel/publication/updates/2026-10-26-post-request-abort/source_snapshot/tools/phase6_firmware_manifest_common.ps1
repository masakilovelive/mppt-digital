function Resolve-Phase6RepositoryRoot([string]$RepoRoot) {
  return (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
}

function Assert-Phase6PathWithinRepository([string]$RepoRoot,
                                           [string]$Path) {
  $repo = Resolve-Phase6RepositoryRoot $RepoRoot
  $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  $prefix = $repo + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($prefix,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw "Phase 6 manifest path escaped repository: $full"
  }
  return $full
}

function Get-Phase6RelativePath([string]$RepoRoot, [string]$Path) {
  $repo = Resolve-Phase6RepositoryRoot $RepoRoot
  $full = Assert-Phase6PathWithinRepository $repo $Path
  return $full.Substring($repo.Length).TrimStart('\', '/').Replace('\', '/')
}

function Get-Phase6ManifestSourceFiles([string]$RepoRoot) {
  $repo = Resolve-Phase6RepositoryRoot $RepoRoot
  $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

  $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\src') -File -Filter '*.cpp'))
  $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'core\include\vc_lora') -File -Filter '*.hpp'))
  $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      (Join-Path $repo 'firmware\phase6') -File))

  foreach ($role in @(
      'vc_lora_vehicle_xiao_esp32s3',
      'vc_lora_ground_xiao_esp32s3'
    )) {
    $sketchRoot = Join-Path $repo $role
    $files.Add((Get-Item -LiteralPath `
        (Join-Path $sketchRoot "$role.ino") -ErrorAction Stop))
    $files.Add((Get-Item -LiteralPath `
        (Join-Path $sketchRoot 'VC_LoRa_Core.h') -ErrorAction Stop))
    $files.Add((Get-Item -LiteralPath `
        (Join-Path $sketchRoot 'vc_lora_phase6_bridge.hpp') `
        -ErrorAction Stop))
    $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
        (Join-Path $sketchRoot 'src') -File -Filter '*.cpp'))
    $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
        (Join-Path $sketchRoot 'vc_lora') -File -Filter '*.hpp'))
  }

  foreach ($relative in @(
      'tools\compile_arduino.ps1',
      'tools\install_patched_esp32_hwcdc.ps1',
      'tools\invoke_phase6_manifest_flash.ps1',
      'tools\phase6_firmware_manifest_common.ps1',
      'tools\sync_arduino_sketch_core.ps1',
      'tools\verify_phase6_firmware_manifest.ps1',
      'tools\write_phase6_firmware_manifest.ps1',
      'tests\arduino_compile\check_phase6_firmware_contract.ps1',
      'tests\arduino_compile\check_phase6_ide_compile.ps1',
      'tests\arduino_compile\check_hwcdc_tx_integrity_contract.ps1',
      'tests\arduino_compile\check_phase6_compile_publication_behavior.ps1',
      'tests\arduino_compile\check_phase6_manifest_tooling_contract.ps1',
      'tests\hil\check_phase6_manifest_flash_contract.ps1'
    )) {
    $files.Add((Get-Item -LiteralPath (Join-Path $repo $relative) `
        -ErrorAction Stop))
  }

  $thirdParty = Join-Path $repo 'third_party\esp32-core-3.3.11-vc-lora'
  $files.AddRange([System.IO.FileInfo[]]@(Get-ChildItem -LiteralPath `
      $thirdParty -Recurse -File))

  $byRelativePath = @{}
  foreach ($file in $files) {
    $relative = Get-Phase6RelativePath $repo $file.FullName
    $key = $relative.ToUpperInvariant()
    if ($byRelativePath.ContainsKey($key)) {
      throw "Duplicate Phase 6 source path: $relative"
    }
    $byRelativePath[$key] = $file
  }

  $relativePaths = [string[]]@($byRelativePath.Keys)
  [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
  return @($relativePaths | ForEach-Object { $byRelativePath[$_] })
}

function New-Phase6FileRecord([string]$RepoRoot,
                              [System.IO.FileInfo]$File) {
  $bytes = [IO.File]::ReadAllBytes($File.FullName)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
  return [pscustomobject][ordered]@{
    path = Get-Phase6RelativePath $RepoRoot $File.FullName
    size_bytes = [int64]$bytes.LongLength
    sha256 = $hash
  }
}

function Get-Phase6CanonicalTreeHash([object[]]$Records) {
  $lines = @($Records | ForEach-Object {
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

function Get-Phase6SourceSnapshot([string]$RepoRoot) {
  $repo = Resolve-Phase6RepositoryRoot $RepoRoot
  $records = @(
    Get-Phase6ManifestSourceFiles $repo |
      ForEach-Object { New-Phase6FileRecord $repo $_ }
  )
  return [pscustomobject][ordered]@{
    file_count = $records.Count
    tree_sha256 = Get-Phase6CanonicalTreeHash $records
    records = $records
  }
}
