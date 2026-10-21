[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [ValidateRange(0, 255)]
  [int]$Sequence = 99,

  [ValidateRange(1, 255)]
  [int]$TargetSystem = 1,

  [ValidateRange(1, 255)]
  [int]$TargetComponent = 1,

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

function New-ParamRequestListFrame {
  param([byte]$Seq, [byte]$TargetSys, [byte]$TargetComp)
  [byte[]]$frame = New-Object byte[] 14
  $frame[0] = 0xFD
  $frame[1] = 2
  $frame[4] = $Seq
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 21
  $frame[10] = $TargetSys
  $frame[11] = $TargetComp
  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 12; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $frame[$index]
  }
  $crc = Update-X25Crc -Crc $crc -Value 159
  $frame[12] = [byte]($crc -band 0xFF)
  $frame[13] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

if ($SelfTest) {
  $known = New-ParamRequestListFrame -Seq 99 -TargetSys 1 -TargetComp 1
  $actual = -join ($known | ForEach-Object { $_.ToString('X2') })
  $expected = 'FD02000063FFBE1500000101D507'
  if ($actual -ne $expected) {
    throw "PARAM_REQUEST_LIST fixture self-test mismatch: $actual"
  }
  Write-Output 'PARAM_REQUEST_LIST fixture self-test PASS'
  return
}

if (Test-Path -LiteralPath $OutputPath) {
  throw "Refusing to overwrite existing fixture: $OutputPath"
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$bytes = New-ParamRequestListFrame -Seq ([byte]$Sequence) `
  -TargetSys ([byte]$TargetSystem) -TargetComp ([byte]$TargetComponent)
[IO.File]::WriteAllBytes($OutputPath, $bytes)
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash
Write-Output ("CREATED PARAM_REQUEST_LIST bytes={0} sha256={1} path={2}" -f `
    $bytes.Length, $hash, (Resolve-Path $OutputPath).Path)
