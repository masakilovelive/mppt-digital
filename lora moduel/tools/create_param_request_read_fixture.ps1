[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateLength(1, 16)]
  [string]$ParamId,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [ValidateRange(0, 255)]
  [int]$Sequence = 1,

  [ValidateRange(1, 255)]
  [int]$TargetSystem = 1,

  [ValidateRange(1, 255)]
  [int]$TargetComponent = 1,

  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-X25Crc {
  param(
    [Parameter(Mandatory = $true)]
    [uint16]$Crc,

    [Parameter(Mandatory = $true)]
    [byte]$Value
  )

  [int]$tmp = ($Value -bxor ($Crc -band 0xFF)) -band 0xFF
  $tmp = ($tmp -bxor (($tmp -shl 4) -band 0xFF)) -band 0xFF
  return [uint16]((($Crc -shr 8) -bxor ($tmp -shl 8) -bxor
        ($tmp -shl 3) -bxor ($tmp -shr 4)) -band 0xFFFF)
}

function New-ParamRequestReadFrame {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [byte]$Seq,

    [Parameter(Mandatory = $true)]
    [byte]$TargetSys,

    [Parameter(Mandatory = $true)]
    [byte]$TargetComp
  )

  $nameBytes = [Text.Encoding]::ASCII.GetBytes($Name)
  if ([Text.Encoding]::ASCII.GetString($nameBytes) -ne $Name -or
      $nameBytes.Length -gt 16) {
    throw 'ParamId must contain 1-16 ASCII characters'
  }

  # MAVLink 2 PARAM_REQUEST_READ, deliberately emitted at its canonical
  # full payload length (20 bytes) so the bridge's explicit min/max contract
  # and the 32-byte E220 physical write are both exercised.
  [byte[]]$frame = New-Object byte[] 32
  $frame[0] = 0xFD
  $frame[1] = 20
  $frame[2] = 0
  $frame[3] = 0
  $frame[4] = $Seq
  $frame[5] = 255
  $frame[6] = 190
  $frame[7] = 20
  $frame[8] = 0
  $frame[9] = 0
  $frame[10] = 0xFF
  $frame[11] = 0xFF
  $frame[12] = $TargetSys
  $frame[13] = $TargetComp
  [Array]::Copy($nameBytes, 0, $frame, 14, $nameBytes.Length)

  [uint16]$crc = 0xFFFF
  for ($index = 1; $index -lt 30; ++$index) {
    $crc = Update-X25Crc -Crc $crc -Value $frame[$index]
  }
  $crc = Update-X25Crc -Crc $crc -Value 214  # CRC_EXTRA for msgid 20.
  $frame[30] = [byte]($crc -band 0xFF)
  $frame[31] = [byte](($crc -shr 8) -band 0xFF)
  return $frame
}

if ($SelfTest) {
  $known = New-ParamRequestReadFrame -Name 'ARMING_CHECK' -Seq 1 `
    -TargetSys 1 -TargetComp 1
  $knownHex = -join ($known | ForEach-Object { $_.ToString('X2') })
  $expectedHex =
    'FD14000001FFBE140000FFFF010141524D494E475F434845434B0000000098F6'
  if ($knownHex -ne $expectedHex) {
    throw "fixture self-test mismatch: $knownHex"
  }
  Write-Output 'PARAM_REQUEST_READ fixture self-test PASS'
  return
}

if (Test-Path -LiteralPath $OutputPath) {
  throw "Refusing to overwrite existing fixture: $OutputPath"
}
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$bytes = New-ParamRequestReadFrame -Name $ParamId `
  -Seq ([byte]$Sequence) -TargetSys ([byte]$TargetSystem) `
  -TargetComp ([byte]$TargetComponent)
[IO.File]::WriteAllBytes($OutputPath, $bytes)
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash
Write-Output ("CREATED PARAM_REQUEST_READ id={0} bytes={1} sha256={2} path={3}" -f `
    $ParamId, $bytes.Length, $hash, (Resolve-Path $OutputPath).Path)
