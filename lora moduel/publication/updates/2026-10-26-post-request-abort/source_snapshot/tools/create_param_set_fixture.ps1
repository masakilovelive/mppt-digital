[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateLength(1, 16)]
  [string]$ParamId,

  [Parameter(Mandatory = $true)]
  [single]$Value,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 9)]
  [int]$ParamType,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [ValidateRange(0, 255)]
  [int]$Sequence = 57,

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

function New-ParamSetFrame {
  param([string]$Name, [single]$ParamValue, [byte]$Type, [byte]$Seq)

  $nameBytes = [Text.Encoding]::ASCII.GetBytes($Name)
  if ([Text.Encoding]::ASCII.GetString($nameBytes) -ne $Name -or
      $nameBytes.Length -gt 16) {
    throw 'ParamId must contain 1-16 ASCII characters'
  }

  [byte[]]$frame = New-Object byte[] 35
  $frame[0] = 0xFD
  $frame[1] = 23
  $frame[4] = $Seq
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 23
  [Array]::Copy([BitConverter]::GetBytes($ParamValue), 0, $frame, 10, 4)
  $frame[14] = 1
  $frame[15] = 1
  [Array]::Copy($nameBytes, 0, $frame, 16, $nameBytes.Length)
  $frame[32] = $Type

  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 33; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $frame[$index]
  }
  $crc = Update-X25Crc -Crc $crc -Value 168
  $frame[33] = [byte]($crc -band 0xFF)
  $frame[34] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

if ($SelfTest) {
  $known = New-ParamSetFrame -Name 'VCTD_COLLISION' -ParamValue 1.0 `
    -Type 9 -Seq 0x39
  $hex = -join ($known | ForEach-Object { $_.ToString('X2') })
  $expected = 'FD17000039FFBE1700000000803F0101564354445F434F4C4C4953494F4E0000099558'
  if ($hex -ne $expected) {
    throw "PARAM_SET fixture self-test mismatch: $hex"
  }
  Write-Output 'PARAM_SET fixture self-test PASS'
  return
}

if (Test-Path -LiteralPath $OutputPath) {
  throw "Refusing to overwrite existing fixture: $OutputPath"
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$bytes = New-ParamSetFrame -Name $ParamId -ParamValue $Value `
  -Type ([byte]$ParamType) -Seq ([byte]$Sequence)
[IO.File]::WriteAllBytes($OutputPath, $bytes)
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash
Write-Output ("CREATED PARAM_SET id={0} value={1} type={2} bytes={3} sha256={4} path={5}" -f `
    $ParamId, $Value, $ParamType, $bytes.Length, $hash,
    (Resolve-Path $OutputPath).Path)
