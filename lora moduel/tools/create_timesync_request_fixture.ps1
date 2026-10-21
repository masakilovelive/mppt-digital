[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [ValidateRange(0, 255)]
  [int]$Sequence = 167,

  [uint64]$Timestamp = 0x1122334455667788,

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

function New-TimesyncRequestFrame {
  param([byte]$Seq, [uint64]$Ts1)

  [byte[]]$frame = New-Object byte[] 28
  $frame[0] = 0xFD
  $frame[1] = 16
  $frame[4] = $Seq
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 111
  [Array]::Copy([BitConverter]::GetBytes($Ts1), 0, $frame, 18, 8)

  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 26; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $frame[$index]
  }
  $crc = Update-X25Crc -Crc $crc -Value 34
  $frame[26] = [byte]($crc -band 0xFF)
  $frame[27] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

$bytes = New-TimesyncRequestFrame -Seq ([byte]$Sequence) -Ts1 $Timestamp
$hex = -join ($bytes | ForEach-Object { $_.ToString('X2') })

if ($SelfTest) {
  $expected = 'FD100000A7FFBE6F000000000000000000008877665544332211BB82'
  if ($hex -ne $expected) {
    throw "TIMESYNC fixture self-test mismatch: $hex"
  }
  Write-Output 'TIMESYNC fixture self-test PASS'
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
Write-Output ("CREATED TIMESYNC bytes={0} sha256={1} path={2}" -f `
    $bytes.Length, $hash, (Resolve-Path $OutputPath).Path)
