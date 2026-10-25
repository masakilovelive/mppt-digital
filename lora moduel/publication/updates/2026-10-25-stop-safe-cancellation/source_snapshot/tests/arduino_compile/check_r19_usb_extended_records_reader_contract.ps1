[CmdletBinding()]
param([string]$OutputRoot)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$reader = Join-Path $repo 'tools\read_r19_runtime_stage_jtag.ps1'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('r19-extended-reader-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRoot = (Resolve-Path $OutputRoot).Path
$checks = [Collections.Generic.List[object]]::new()
$shellPath = if ($PSVersionTable.PSEdition -eq 'Core') {
  Join-Path $PSHOME 'pwsh.exe'
} else { Join-Path $PSHOME 'powershell.exe' }
function Pack-Words([uint32[]]$Words) {
  $bytes = [byte[]]::new($Words.Count * 4)
  for ($i = 0; $i -lt $Words.Count; ++$i) { [BitConverter]::GetBytes($Words[$i]).CopyTo($bytes, $i * 4) }
  return ,$bytes
}
function New-Fixture {
  [uint32[]]$stage = @(0,24,0x52313953,1,1,0x52313944,0x53544731,0x32303236,0x31303033,0x7fff,1,11,2,3,0,0,0)
  [uint32[]]$fifo = @(0,40,0x48313946,2,15,2,2,64,0,32,3,2,2,2,2,0,2,2,0,1,0,0,0x80,0,2,1,0,0)
  [uint32[]]$restart = [uint32[]]::new(32)
  $restart[1]=2; $restart[2]=0x48313952; $restart[3]=1; $restart[4]=1
  [uint32[]]$commit = [uint32[]]::new(32)
  $commit[1]=2; $commit[2]=0x52313943; $commit[3]=1; $commit[4]=1
  for ($i=0; $i-lt4; ++$i) { $commit[5+$i]=$stage[5+$i] }
  $fixture = [ordered]@{
    schema='vc-lora-r19-usb-extended-jtag-fixture-v1'; artifact_id='offline-extension-fixture'; role='ground'
    runtime_stage_address='0x3fcab000'; endpoint_fifo_address='0x3fcab100'
    hwcdc_restart_address='0x3fcab200'; ground_usb_commit_address='0x3fcab300'
    runtime_stage_first_read_base64=[Convert]::ToBase64String((Pack-Words $stage))
    runtime_stage_second_read_base64=[Convert]::ToBase64String((Pack-Words $stage))
    endpoint_fifo_first_read_base64=[Convert]::ToBase64String((Pack-Words $fifo))
    endpoint_fifo_second_read_base64=[Convert]::ToBase64String((Pack-Words $fifo))
    hwcdc_restart_first_read_base64=[Convert]::ToBase64String((Pack-Words $restart))
    hwcdc_restart_second_read_base64=[Convert]::ToBase64String((Pack-Words $restart))
    ground_usb_commit_first_read_base64=[Convert]::ToBase64String((Pack-Words $commit))
    ground_usb_commit_second_read_base64=[Convert]::ToBase64String((Pack-Words $commit))
  }
  $fixture
}
function Set-Word($Fixture,[string]$Record,[int]$Index,[uint32]$Value,[switch]$FirstOnly) {
  foreach ($sample in @('first','second')) {
    if ($FirstOnly -and $sample-eq'second') { continue }
    $key=$Record+'_'+$sample+'_read_base64'
    $bytes=[Convert]::FromBase64String($Fixture[$key])
    [BitConverter]::GetBytes($Value).CopyTo($bytes,4*$Index)
    $Fixture[$key]=[Convert]::ToBase64String($bytes)
  }
}
function New-LatchedFixture {
  $f=New-Fixture
  foreach($item in @(@(4,7),@(5,2),@(6,1),@(7,1),@(8,1),@(9,1),@(10,15),@(11,1),@(12,31),@(14,2),@(15,2),@(18,2),@(19,1),@(20,31),@(21,31),@(22,2),@(23,31),@(24,1),@(27,3),@(28,2),@(29,0x80),@(30,0x80))){
    Set-Word $f 'hwcdc_restart' $item[0] $item[1]
  }
  foreach($item in @(@(9,1),@(10,7),@(11,6),@(12,3178),@(13,7),@(14,1),@(15,1),@(16,4800),@(18,4810),@(20,4900),@(22,4916),@(24,100),@(26,121),@(28,121),@(30,21),@(31,21))){
    Set-Word $f 'ground_usb_commit' $item[0] $item[1]
  }
  $f
}
function Run-Case([string]$Name,$Fixture,[bool]$ExpectedPass,[string[]]$Extra=@()) {
  $caseRoot=Join-Path $OutputRoot $Name
  New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
  $fixturePath=Join-Path $caseRoot 'fixture.json'
  $Fixture|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $fixturePath -Encoding UTF8
  $stdout=Join-Path $caseRoot 'stdout.txt'; $stderr=Join-Path $caseRoot 'stderr.txt'
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$reader+'"'),'-OfflineExtendedRecordFixtureOnly','-FixturePath',('"'+$fixturePath+'"'),'-OutputRoot',('"'+(Join-Path $caseRoot 'read')+'"'))+$Extra
  $p=Start-Process -FilePath $shellPath -ArgumentList $args -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $summaryPath=Join-Path $caseRoot 'read\summary.json'
  $record=if(Test-Path $summaryPath){Get-Content $summaryPath -Raw|ConvertFrom-Json}else{$null}
  $pass=if($ExpectedPass){$p.ExitCode-eq0-and$null-ne$record-and$record.result-eq'PASS'-and$record.hardware_interaction-eq$false-and$record.live_binding_supported-eq$false-and@($record.reads).Count-eq8-and$record.schema-eq'vc-lora-r19-usb-extended-offline-read-v1'}else{$p.ExitCode-ne0}
  $checks.Add([ordered]@{name=$Name;passed=[bool]$pass;expected_pass=$ExpectedPass;exit_code=$p.ExitCode})
  [pscustomobject]@{summary=$record;root=$caseRoot;passed=$pass}
}

$valid=New-Fixture
$positive=Run-Case 'unlatched-records-valid' $valid $true
$latched=Run-Case 'latched-records-valid' (New-LatchedFixture) $true
$f=New-LatchedFixture; Set-Word $f 'ground_usb_commit' 9 3; Set-Word $f 'ground_usb_commit' 11 5
[void](Run-Case 'postflush-retired-transport-observed' $f $true)
$f=New-LatchedFixture; Set-Word $f 'ground_usb_commit' 9 2; Set-Word $f 'ground_usb_commit' 10 6
[void](Run-Case 'preflush-exact-deadline-transport-unobserved' $f $true)
if($latched.passed){
  $d=$latched.summary.decoded
  $checks.Add([ordered]@{name='latched-fields-decoded-with-exact-predicates';passed=($d.hwcdc_restart.first.state.ring_pending_bytes-eq31-and$d.hwcdc_restart.latest.written_bytes-eq31-and$d.ground_usb_commit.source_line-eq3178-and$d.ground_usb_commit.predicates.transport_published.observed-eq$true-and$d.ground_usb_commit.predicates.transport_published.value-eq$false-and$d.ground_usb_commit.predicates.endpoint_ready.value-eq$true-and$d.ground_usb_commit.predicates.completed_within_deadline.value-eq$true-and$d.ground_usb_commit.values.completed_ms-eq4900)})
}
$f=New-Fixture; $f.role='vehicle'; Set-Word $f 'runtime_stage' 4 2; Set-Word $f 'ground_usb_commit' 4 2
[void](Run-Case 'vehicle-unlatched-valid' $f $true)
$f=New-LatchedFixture; Set-Word $f 'ground_usb_commit' 20 ([uint32]::MaxValue); Set-Word $f 'ground_usb_commit' 21 ([uint32]::MaxValue)
$high=Run-Case 'uint64-max-exact' $f $true
if($high.passed){$checks.Add([ordered]@{name='uint64-max-retained-exactly';passed=([string]$high.summary.decoded.ground_usb_commit.values.completed_ms-eq'18446744073709551615')})}
$source=Get-Content $reader -Raw
$checks.Add([ordered]@{name='explicit-offline-only-flag';passed=($source-match'\[switch\]\$OfflineExtendedRecordFixtureOnly')})
foreach($flag in @('-Execute','-Preflight','-OfflineNativeInvocationContractTest','-Role ground')){
  [void](Run-Case ('reject-'+($flag-replace'[^A-Za-z]','')) (New-Fixture) $false ($flag -split ' '))
}
foreach($recordName in @('hwcdc_restart','ground_usb_commit')){
  foreach($mutation in @('writer-active','odd-sequence','different-read','bad-magic','bad-schema','short-record','missing-second')){
    $f=New-Fixture
    switch($mutation){
      'writer-active'{Set-Word $f $recordName 0 1}
      'odd-sequence'{Set-Word $f $recordName 1 3}
      'different-read'{Set-Word $f $recordName 1 4 -FirstOnly}
      'bad-magic'{Set-Word $f $recordName 2 1}
      'bad-schema'{Set-Word $f $recordName 3 2}
      'short-record'{$f[$recordName+'_first_read_base64']=[Convert]::ToBase64String([byte[]]::new(124))}
      'missing-second'{$f.Remove($recordName+'_second_read_base64')}
    }
    [void](Run-Case ('reject-'+$recordName+'-'+$mutation) $f $false)
  }
}
foreach($recordName in @('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')){
  $f=New-Fixture; $f[$recordName+'_address']='0x3fcab001'
  [void](Run-Case ('reject-'+$recordName+'-unaligned') $f $false)
}
$f=New-Fixture; $f.hwcdc_restart_address=$f.ground_usb_commit_address
[void](Run-Case 'reject-overlapping-extensions' $f $false)
$f=New-Fixture; Set-Word $f 'ground_usb_commit' 4 2
[void](Run-Case 'reject-role-mismatch' $f $false)
$f=New-Fixture; Set-Word $f 'ground_usb_commit' 5 1
[void](Run-Case 'reject-generation-fingerprint' $f $false)
$f=New-Fixture; Set-Word $f 'ground_usb_commit' 10 8
[void](Run-Case 'reject-unknown-observed-predicate' $f $false)
$f=New-Fixture; Set-Word $f 'ground_usb_commit' 11 1
[void](Run-Case 'reject-true-predicate-not-observed' $f $false)
$f=New-Fixture; Set-Word $f 'ground_usb_commit' 9 99
[void](Run-Case 'reject-unknown-reason' $f $false)
$f=New-Fixture; Set-Word $f 'hwcdc_restart' 31 1
[void](Run-Case 'reject-restart-reserved-word' $f $false)
foreach($mutation in @('unknown-flags','invalid-counter','invalid-phase','missing-first-valid','invalid-origin','invalid-outcome','oversized-request','written-beyond-request','published-zero','zero-rejected-positive','invalid-generation','unknown-state-flags','reset-before-positive','reset-after-zero','invalidated-positive','published-without-inflight','first-blocked-not-writable','first-blocked-no-pending','first-blocked-unsafe')){
  $f=New-LatchedFixture
  switch($mutation){
    'unknown-flags'{Set-Word $f 'hwcdc_restart' 4 15}
    'invalid-counter'{Set-Word $f 'hwcdc_restart' 6 3}
    'invalid-phase'{Set-Word $f 'hwcdc_restart' 8 3}
    'missing-first-valid'{Set-Word $f 'hwcdc_restart' 4 5}
    'invalid-origin'{Set-Word $f 'hwcdc_restart' 18 3}
    'invalid-outcome'{Set-Word $f 'hwcdc_restart' 19 6}
    'oversized-request'{Set-Word $f 'hwcdc_restart' 20 33}
    'written-beyond-request'{Set-Word $f 'hwcdc_restart' 21 32}
    'published-zero'{Set-Word $f 'hwcdc_restart' 21 0}
    'zero-rejected-positive'{Set-Word $f 'hwcdc_restart' 19 2}
    'invalid-generation'{Set-Word $f 'hwcdc_restart' 27 4}
    'unknown-state-flags'{Set-Word $f 'hwcdc_restart' 23 0x4000}
    'reset-before-positive'{Set-Word $f 'hwcdc_restart' 19 3}
    'reset-after-zero'{Set-Word $f 'hwcdc_restart' 19 4; Set-Word $f 'hwcdc_restart' 21 0}
    'invalidated-positive'{Set-Word $f 'hwcdc_restart' 19 5}
    'published-without-inflight'{Set-Word $f 'hwcdc_restart' 23 15; Set-Word $f 'hwcdc_restart' 27 2}
    'first-blocked-not-writable'{Set-Word $f 'hwcdc_restart' 10 7}
    'first-blocked-no-pending'{Set-Word $f 'hwcdc_restart' 12 0}
    'first-blocked-unsafe'{Set-Word $f 'hwcdc_restart' 10 47}
  }
  [void](Run-Case ('reject-'+$mutation) $f $false)
}
$f=New-LatchedFixture; Set-Word $f 'ground_usb_commit' 31 22
[void](Run-Case 'reject-accepted-beyond-frame' $f $false)
$failed=@($checks|Where-Object{-not $_.passed})
$summary=[ordered]@{schema='vc-lora-r19-usb-extended-reader-contract-v1';result=$(if($failed.Count-eq0){'PASS'}else{'FAIL'});hardware_interaction=$false;checks=@($checks);passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count}
$summary|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 10
if($failed.Count-gt0){exit 1}
