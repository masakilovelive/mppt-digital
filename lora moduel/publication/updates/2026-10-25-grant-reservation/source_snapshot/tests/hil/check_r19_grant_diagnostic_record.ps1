param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$script:checks=0
function Check([bool]$v,[string]$name){if(-not$v){throw "FAIL $name"};$script:checks++}
. (Join-Path $RepoRoot 'tools/read_r19_grant_diagnostic_record.ps1') -ImportOnly
function Bytes([uint32[]]$w){[byte[]]$b=[byte[]]::new(1024);for($i=0;$i-lt256;$i++){[BitConverter]::GetBytes($w[$i]).CopyTo($b,4*$i)};return ,$b}
function U64([uint32[]]$w,[int]$n,[uint64]$v){$w[$n]=[uint32]($v-band[uint64]4294967295);$w[$n+1]=[uint32]($v-shr32)}
function Decode([uint32[]]$w){[byte[]]$b=Bytes $w;ConvertFrom-R19GrantDiagnosticRecord -First $b -Second $b -ExpectedRole ground -ExpectedFingerprint @(1,2,3,4) -ExpectedBoot @(5,6,7,8)}
function Reject([uint32[]]$w,[string]$name){$no=$false;try{$null=Decode $w}catch{$no=$true};Check $no $name}
[uint32[]]$w=[uint32[]]::new(256);$w[1]=2;$w[2]=0x52313947;$w[3]=1;$w[4]=1;$w[13]=1;$w[14]=1024
for($i=0;$i-lt4;$i++){$w[5+$i]=[uint32](1+$i);$w[9+$i]=[uint32](5+$i)}
$d=Decode $w;Check (-not$d.failure_latched-and$d.observation_count-eq0-and$d.expected_identity_bound) 'initialized absent evidence'
$w[1]=4;$w[13]=3;$w[80]=1;$w[81]=1;$w[82]=1;$w[84]=1
$w[16]=5;$w[17]=15;$w[18]=2;$w[19]=9;$w[20]=1;$w[21]=14;$w[22]=24;$w[23]=24;$w[24]=1;$w[25]=0;$w[26]=3;$w[27]=3
U64 $w 28 9007199254741601;U64 $w 30 9007199254741101;U64 $w 32 9007199254741101;$w[44]=2299
for($i=0;$i-lt32;$i++){$w[48+$i]=$w[16+$i]}
$w[96]=1;$w[97]=5;$w[98]=31;U64 $w 99 9007199254741601
$w[101]=2;$w[102]=9;$w[103]=1;$w[104]=14;$w[105]=24;$w[106]=24;$w[107]=1;$w[108]=0;$w[109]=3;$w[110]=3;$w[111]=2299
$d=Decode $w
Check ($d.failure_latched-and$d.first_failure.observed_ms-ceq'9007199254741601'-and$d.first_failure.request_origin_ms-ceq'9007199254741101') 'uint64 clocks never rounded'
Check ($d.first_failure.owner_result-eq24-and$d.journal.Count-eq1-and$d.journal[0].source_line-eq2299) 'failure and ordered journal decoded'
Check ($d.first_failure.owner_result_name-ceq'StaleGrant') 'StaleGrant never mislabeled as500ms deadline'
Check (-not$d.grant_deadline_exceeded_proven-and-not$d.rf_delivery_proven-and-not$d.acceptance_authorized) 'decoder does not manufacture cause or acceptance'
foreach($change in @(@(0,1),@(1,3),@(2,0),@(3,2),@(4,2),@(13,0),@(13,5),@(13,9),@(14,512),@(15,1),@(16,10),@(17,143),@(18,10),@(20,15),@(22,42),@(24,22),@(26,27),@(40,65536),@(45,1),@(47,1),@(81,11),@(82,10),@(83,1),@(84,0),@(85,1),@(95,1),@(96,0),@(97,10),@(98,3),@(98,256),@(101,10),@(103,15),@(105,42),@(105,23),@(107,22),@(109,27),@(112,1),@(255,1))){$bad=[uint32[]]$w.Clone();$bad[$change[0]]=[uint32]$change[1];Reject $bad "reject word $($change[0])=$($change[1])"}
$bad=[uint32[]]$w.Clone();$bad[17]=11;Reject $bad 'unavailable request timestamp rejected'
$bad=[uint32[]]$w.Clone();$bad[13]=1;Reject $bad 'unlatched firstfailure payload rejected'
$deadline=[uint32[]]$w.Clone();foreach($n in @(22,23,54,55,105,106)){$deadline[$n]=25};$d=Decode $deadline
Check ($d.first_failure.owner_result_name-ceq'GrantDeadlineExceeded'-and$d.first_failure.owner_last_error_name-ceq'GrantDeadlineExceeded') 'exact owner deadline result distinguished from stale Grant'
$zero=[uint32[]]$w.Clone();foreach($n in @(30,31,62,63)){$zero[$n]=0};$d=Decode $zero
Check ($d.first_failure.request_origin_ms-ceq'0') 'valid zero-origin timestamp is not unavailable'
[byte[]]$b=Bytes $w;$other=[byte[]]$b.Clone();$other[0]=1;$no=$false;try{$null=ConvertFrom-R19GrantDiagnosticRecord -First $b -Second $other -ExpectedRole ground}catch{$no=$true};Check $no 'unequal paired reads rejected'
$no=$false;try{$null=ConvertFrom-R19GrantDiagnosticRecord -First $b[0..1022] -Second $b -ExpectedRole ground}catch{$no=$true};Check $no 'wrong raw length rejected'
$no=$false;try{$null=ConvertFrom-R19GrantDiagnosticRecord -First $b -Second $b -ExpectedRole ground -ExpectedBoot @(5,6,7,9)}catch{$no=$true};Check $no 'boot mismatch rejected'
$w[4]=2;[byte[]]$b=Bytes $w;$v=ConvertFrom-R19GrantDiagnosticRecord -First $b -Second $b -ExpectedRole vehicle
Check ($v.role-ceq'vehicle'-and-not$v.expected_identity_bound) 'unbound optional identity remains explicit'
Write-Output "GRANT_DIAGNOSTIC_RECORD PASS $script:checks checks"
