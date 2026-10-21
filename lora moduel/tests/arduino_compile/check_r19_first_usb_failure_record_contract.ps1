[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$reader=Join-Path $repo 'tools/read_r19_first_usb_failure_record.ps1'
if (-not $OutputDirectory) { $OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('r19-first-failure-contract-'+[guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$checks=[Collections.Generic.List[object]]::new()
function Fixture([uint32[]]$Words,[uint32[]]$Second=$Words) {
  $bytes=[byte[]]::new(384); $secondBytes=[byte[]]::new(384)
  for ($i=0;$i -lt 96;$i++) { [BitConverter]::GetBytes($Words[$i]).CopyTo($bytes,$i*4); [BitConverter]::GetBytes($Second[$i]).CopyTo($secondBytes,$i*4) }
  [ordered]@{schema='vc-lora-r19-first-usb-failure-fixture-v1'; role='ground'; build_fingerprint=@(1,2,3,4); boot_instance=@(170,187,204,221); first_read_base64=[Convert]::ToBase64String($bytes);second_read_base64=[Convert]::ToBase64String($secondBytes)}
}
function Check([string]$Name,[object]$Fixture,[bool]$Expected) {
  $path=Join-Path $OutputDirectory ($Name+'.fixture.json'); $out=Join-Path $OutputDirectory ($Name+'.decoded.json')
  $Fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
  $savedPreference=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    $messages=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reader -DecodeOnly -FixturePath $path -OutputPath $out 2>&1
    $code=$LASTEXITCODE
  } finally { $ErrorActionPreference=$savedPreference }
  $passed=($code -eq 0) -eq $Expected
  $messages | Out-String | Set-Content -LiteralPath (Join-Path $OutputDirectory ($Name+'.log')) -Encoding utf8
  $checks.Add([ordered]@{name=$Name;passed=$passed;expected_success=$Expected;exit_code=$code})
  if (-not $passed) { Write-Output "FAIL $Name" }
}
[uint32[]]$w=[uint32[]]::new(96)
$w[1]=6;$w[2]=0x52313955;$w[3]=1;$w[4]=1
$w[5]=1;$w[6]=2;$w[7]=3;$w[8]=4;$w[9]=170;$w[10]=187;$w[11]=204;$w[12]=221;$w[13]=3
$w[20]=1;$w[21]=3243;$w[22]=123;$w[23]=1;$w[24]=13;$w[25]=106;$w[26]=1;$w[27]=1
$w[28]=5229000;$w[30]=5335000;$w[32]=5335000;$w[34]=21;$w[35]=21
$w[60]=5335010
$w[36]=1;$w[37]=31;$w[38]=123;$w[39]=1;$w[40]=5;$w[41]=100;$w[46]=106;$w[47]=0;$w[50]=31
Check 'valid-first' (Fixture $w) $true
$m=$w.Clone();$m[0]=1;Check 'active-writer' (Fixture $m) $false
$m=$w.Clone();$m[1]=7;Check 'odd-sequence' (Fixture $m) $false
$m=$w.Clone();$m[23]=2;Check 'different-read' (Fixture $w $m) $false
$m=$w.Clone();$m[2]=0;Check 'bad-magic' (Fixture $m) $false
$m=$w.Clone();$m[3]=2;Check 'future-schema' (Fixture $m) $false
$m=$w.Clone();$m[4]=2;Check 'wrong-role' (Fixture $m) $false
$m=$w.Clone();$m[5]=99;Check 'wrong-fingerprint' (Fixture $m) $false
$m=$w.Clone();$m[9]=99;Check 'wrong-boot' (Fixture $m) $false
$m=$w.Clone();$m[62]=1;Check 'nonzero-reserved' (Fixture $m) $false
$m=$w.Clone();$m[60]=5334999;Check 'failure-before-return' (Fixture $m) $false
$m=$w.Clone();$m[24]=29;Check 'unknown-wrapper-bit' (Fixture $m) $false
$m=$w.Clone();$m[38]=124;Check 'wrong-sdk-token' (Fixture $m) $false
$m=$w.Clone();$m[40]=7;Check 'unknown-sdk-terminal' (Fixture $m) $false
$m=$w.Clone();$m[48]=0x4000;Check 'unknown-sdk-state-flag' (Fixture $m) $false
$m=$w.Clone();$m[56]=0x100;Check 'unknown-sdk-blocker-flag' (Fixture $m) $false
$m=$w.Clone();$m[37]=23;Check 'unobserved-sdk-state' (Fixture $m) $false
$m=$w.Clone();$m[37]=151;for($i=48;$i -lt 60;$i++){$m[$i]=0};Check 'unobserved-sdk-lockless-bit' (Fixture $m) $false
$m=$w.Clone();$m[37]=19;$m[40]=2;for($i=48;$i -lt 60;$i++){$m[$i]=0};Check 'null-ring-snapshot-unobserved' (Fixture $m) $true
$m=$w.Clone();$m[35]=22;Check 'accepted-over-frame' (Fixture $m) $false
$m=$w.Clone();$m[13]=7;$m[14]=1;$m[16]=0x123;$m[17]=0x52190000;$m[18]=6000000;Check 'same-boot-sync' (Fixture $m) $true
$m[17]=0x52180000;Check 'foreign-sync-nonce' (Fixture $m) $false
$m=$w.Clone();$m[13]=7;$m[14]=1;$m[16]=0x123;$m[17]=0x52190000;$m[18]=66;$m[19]=[Convert]::ToUInt32('ABCDEF01',16)
$m[28]=1;$m[29]=0x12345678;$m[30]=106001;$m[31]=0x12345678;$m[32]=106001;$m[33]=0x12345678;$m[60]=106011;$m[61]=0x12345678
Check 'full-width-uint64' (Fixture $m) $true
$wide=Get-Content -LiteralPath (Join-Path $OutputDirectory 'full-width-uint64.decoded.json') -Raw | ConvertFrom-Json
$checks.Add([ordered]@{name='full-width-string-exactness';passed=($wide.clock_sync.device_us -is [string] -and $wide.clock_sync.device_us -ceq '12379813738285367362' -and $wide.first_failure.started_us -ceq '1311768464867721217');expected_success=$true;exit_code=0})
$m=$w.Clone();$m[24]=4;for($i=36;$i -lt 60;$i++){$m[$i]=0};$m[36]=1;Check 'api-not-called-unknown' (Fixture $m) $true
$m=$w.Clone();for($i=20;$i -lt 62;$i++){$m[$i]=0};$m[13]=1;Check 'unlatched-not-failed' (Fixture $m) $true
$m[4]=2;$fixture=Fixture $m;$fixture.role='vehicle';Check 'vehicle-unlatched-identity' $fixture $true
$fixture=Fixture $w;$fixture.first_read_base64=[Convert]::ToBase64String([byte[]]::new(380));Check 'short-record' $fixture $false
$fixture=Fixture $w;$fixture.schema='vc-lora-r19-first-usb-failure-fixture-v2';Check 'future-fixture' $fixture $false
$failed=@($checks | Where-Object {-not $_.passed}).Count
$summary=[ordered]@{schema='r19-first-usb-failure-decoder-contract-v1';result=$(if($failed -eq 0){'PASS'}else{'FAIL'});hardware_interaction=$false;checks=@($checks);check_count=$checks.Count;failed_count=$failed}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
Write-Output "R19-FIRST-USB-FAILURE-DECODER checks=$($checks.Count) failed=$failed"
if($failed -gt 0){exit 1};exit 0
