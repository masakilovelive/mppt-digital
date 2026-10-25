param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $RepoRoot 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$script:checks=0
function Check([bool]$v,[string]$name){if(-not$v){throw "FAIL $name"};$script:checks++}
function Reject([scriptblock]$body,[string]$name){$bad=$false;try{$null=&$body}catch{$bad=$true};Check $bad $name}
$now=[DateTime]::new(2026,10,24,7,0,0,[DateTimeKind]::Utc)
$argsPermit=@{Mode='ExplicitHostArm';CandidateId='utc-type-test';HandoffSha256=('A'*64);FlashEvidenceSha256=('B'*64);NowUtc=$now}
function Permit($Issued,$Expires){
  [pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='utc-type-test';mode='ExplicitHostArm'
    handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$Issued;expires_utc=$Expires;safety_confirmed=$true;one_time=$true;restore_required=$true;capture_seconds=40
    ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='USB\V';usb_parent_instance_id='USB\PV'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='USB\G';usb_parent_instance_id='USB\PG'})}
}
$string=Permit $now.AddSeconds(-1).ToString('o') $now.AddSeconds(119).ToString('o')
Check ((Test-R19TimedPathExecutionPermit -Permit $string @argsPermit).valid) 'UTC string exactly120-second TTL remains valid'
$native=Permit $now.AddSeconds(-1) $now.AddSeconds(119)
Check ((Test-R19TimedPathExecutionPermit -Permit $native @argsPermit).valid) 'native UTC DateTime keeps Kind and precise ticks'
$roundtrip=$string|ConvertTo-Json -Depth 10|ConvertFrom-Json
Check ((Test-R19TimedPathExecutionPermit -Permit $roundtrip @argsPermit).valid) 'JSON roundtrip valid on both PowerShell5.1 strings and PowerShell7 UTC DateTime'
$issued=$now.AddTicks(-12345);$expires=$now.AddTicks(1)
Check ((Test-R19TimedPathExecutionPermit -Permit (Permit $issued $expires) @argsPermit).valid) 'native UTC subsecond precision preserves one-tick expiry margin'
Check ((Test-R19TimedPathExecutionPermit -Permit (Permit $issued.ToString('o') $expires.ToString('o')) @argsPermit).valid) 'string UTC subsecond precision preserves one-tick expiry margin'
$atIssue=Permit $now $now.AddSeconds(120)
Check ((Test-R19TimedPathExecutionPermit -Permit $atIssue @argsPermit).valid) 'issued equal now inclusive, TTL120 inclusive'
foreach($representation in @('native','string')){
  foreach($case in @('expired','future','ttl121','ttl120-plus-one-tick','negative-ttl','zero-ttl')){
    $i=$now.AddSeconds(-1);$e=$now.AddSeconds(119)
    switch($case){
      'expired'{$e=$now}
      'future'{$i=$now.AddTicks(1);$e=$now.AddSeconds(1)}
      'ttl121'{$e=$i.AddSeconds(121)}
      'ttl120-plus-one-tick'{$e=$i.AddSeconds(120).AddTicks(1)}
      'negative-ttl'{$e=$i.AddTicks(-1)}
      'zero-ttl'{$e=$i}
    }
    if($representation-ceq'string'){$i=$i.ToString('o');$e=$e.ToString('o')}
    $p=Permit $i $e;Reject {Test-R19TimedPathExecutionPermit -Permit $p @argsPermit} ($representation+' reject '+$case)
  }
}
foreach($kind in @([DateTimeKind]::Local,[DateTimeKind]::Unspecified)){
  foreach($field in @('issued_utc','expires_utc')){
    $p=Permit $now.AddSeconds(-1) $now.AddSeconds(119);$p.$field=[DateTime]::SpecifyKind($p.$field,$kind)
    Reject {Test-R19TimedPathExecutionPermit -Permit $p @argsPermit} ('reject '+$kind+' '+$field)
  }
}
foreach($value in @($null,0,1234,$true,@('2026-10-24T07:00:00Z'),([DateTimeOffset]::new($now)))){
  $p=Permit $value $now.AddSeconds(119);Reject {Test-R19TimedPathExecutionPermit -Permit $p @argsPermit} 'non-string/non-DateTime timestamp rejected'
}
foreach($value in @('2026-10-24T06:59:59','not-a-date','2026-10-24T15:59:59+09:00')){
  $p=Permit $value $now.AddSeconds(119);Reject {Test-R19TimedPathExecutionPermit -Permit $p @argsPermit} 'non-UTC or malformed timestamp string rejected'
}
foreach($kind in @([DateTimeKind]::Local,[DateTimeKind]::Unspecified)){
  $argsBad=$argsPermit.Clone();$argsBad.NowUtc=[DateTime]::SpecifyKind($now,$kind)
  Reject {Test-R19TimedPathExecutionPermit -Permit $native @argsBad} 'comparison clock must be explicitly UTC'
}
foreach($field in @('safety_confirmed','one_time','restore_required')){
  $p=Permit $now.AddSeconds(-1) $now.AddSeconds(119);$p.$field=$false
  Reject {Test-R19TimedPathExecutionPermit -Permit $p @argsPermit} 'UTC type fix cannot bypass safety authorization'
}
Write-Output "R19_PERMIT_UTC_TYPES PASS $script:checks checks; no hardware interaction"
