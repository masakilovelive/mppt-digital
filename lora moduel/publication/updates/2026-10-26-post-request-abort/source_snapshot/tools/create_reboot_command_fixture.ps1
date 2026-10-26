[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [ValidateRange(0, 255)]
  [int]$Sequence = 202,

  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-X25Crc {
  param([uint16]$Crc, [byte]$Value)
  [int]$tmp = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $tmp = ($tmp -bxor (($tmp -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($tmp -shl 8) -bxor
        ($tmp -shl 3) -bxor ($tmp -shr 4)) -band 0xFFFF)
}

function New-RebootFrame {
  param([byte]$Seq)
  [byte[]]$frame = New-Object byte[] 45
  $frame[0] = 0xFD
  $frame[1] = 33
  $frame[4] = $Seq
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 76
  [Array]::Copy([BitConverter]::GetBytes([single]1.0), 0, $frame, 10, 4)
  $frame[38] = 246
  $frame[39] = 0
  $frame[40] = 1
  $frame[41] = 1

  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 43; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $frame[$index]
  }
  $crc = Update-X25Crc -Crc $crc -Value 152
  $frame[43] = [byte]($crc -band 0xFF)
  $frame[44] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

$bytes = New-RebootFrame -Seq ([byte]$Sequence)
if ($SelfTest) {
  if ($bytes.Length -ne 45 -or $bytes[0] -ne 0xFD -or
      $bytes[7] -ne 76 -or $bytes[38] -ne 246) {
    throw 'COMMAND_LONG reboot fixture self-test mismatch'
  }
  Write-Output 'COMMAND_LONG reboot fixture self-test PASS'
  return
}

if (Test-Path -LiteralPath $OutputPath) {
  throw "Refusing to overwrite existing fixture: $OutputPath"
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
[IO.File]::WriteAllBytes($OutputPath, $bytes)
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash
Write-Output ("CREATED REBOOT COMMAND_LONG bytes={0} sha256={1} path={2}" -f `
    $bytes.Length, $hash, (Resolve-Path $OutputPath).Path)
