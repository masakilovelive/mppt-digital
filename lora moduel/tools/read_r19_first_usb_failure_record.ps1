[CmdletBinding()]
param(
  [switch]$DecodeOnly,
  [switch]$TestOnly,
  [switch]$ImportOnly,
  [string]$FixturePath,
  [string]$OutputPath
)
# Pure byte decoding only. ImportOnly defines this function without I/O/exit.
function ConvertFrom-R19FirstUsbFailureBytes {
param([byte[]]$First,[byte[]]$Second,[ValidateSet('ground','vehicle')][string]$ExpectedRole,
  [object[]]$ExpectedFingerprint,[AllowNull()][object[]]$ExpectedBoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Require([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function U64([uint32[]]$Words,[int]$Low) { return ([uint64]$Words[$Low] + ([uint64]$Words[$Low+1] * [uint64]4294967296)) }
function WordsEqual([object]$Expected,[uint32[]]$Words,[int]$Offset) {
  Require (@($Expected).Count -eq 4) 'Identity must have four uint32 words'
  for($i=0;$i -lt 4;$i++) { Require ([decimal]$Expected[$i] -ge 0 -and [decimal]$Expected[$i] -le [uint32]::MaxValue -and [decimal]$Expected[$i] -eq [math]::Floor([decimal]$Expected[$i])) 'Non-uint32 identity';Require ([uint32]$Expected[$i] -eq $Words[$Offset+$i]) 'Identity mismatch' }
}
  [byte[]]$a=$First
  [byte[]]$b=$Second
  Require ($ExpectedRole -ceq 'ground' -or $ExpectedRole -ceq 'vehicle') 'Unknown expected role'
  Require ($a.Length -eq 384 -and $b.Length -eq 384) 'Record size must be exactly 384 bytes'
  for($i=0;$i -lt 384;$i++) { Require ($a[$i] -eq $b[$i]) 'Two reads differ' }
  [uint32[]]$w=[uint32[]]::new(96)
  for($i=0;$i -lt 96;$i++) { $w[$i]=[BitConverter]::ToUInt32($a,$i*4) }
  Require ($w[0] -eq 0 -and ($w[1] -band 1) -eq 0) 'Unstable seqlock sample'
  Require ($w[2] -eq 0x52313955 -and $w[3] -eq 1) 'Unknown record magic/schema'
  $roleCode=if($ExpectedRole -ceq 'ground'){1}else{2}
  Require ($w[4] -eq $roleCode) 'Role mismatch'
  WordsEqual $ExpectedFingerprint $w 5
  if($null-ne$ExpectedBoot){WordsEqual $ExpectedBoot $w 9}
  Require (($w[9] -bor $w[10] -bor $w[11] -bor $w[12]) -ne 0) 'Zero boot identity'
  Require (($w[13] -band 1) -ne 0 -and ($w[13] -band 0xFFFFFFF8L) -eq 0) 'Unknown or uninitialized flags'
  Require ($w[15] -eq 0) 'Reserved header must be zero'
  for($i=62;$i -lt 96;$i++) { Require ($w[$i] -eq 0) 'Reserved body must be zero' }
  $latched=($w[13] -band 2) -ne 0; $sync=($w[13] -band 4) -ne 0
  $nonce=U64 $w 16;$syncUs=U64 $w 18
  if($sync) { Require ($w[14] -gt 0 -and $w[17] -ge 0x52190000 -and $w[17] -le 0x5219FFFF -and (($nonce -band [uint64]281474976710655) -ne 0)) 'Invalid clock sync nonce/count' }
  else { Require ($w[14] -eq 0 -and $nonce -eq 0 -and $syncUs -eq 0) 'Sync unobserved but nonzero' }
  $called=($w[24] -band 1) -ne 0;$rawReturn=$null
  [string[]]$sdkNames=@('schema','validity_flags','transaction_token','attempt_id','terminal_reason','timeout_ms','expected_loss_epoch','started_ms','finished_ms','lock_wait_ms','elapsed_ms','raw_return','state_flags','observed_loss_epoch','ring_pending_bytes','stash_pending_bytes','publish_generation','pickup_generation','raw_interrupt_status','interrupt_enable_mask','flush_blocker_mask','snapshot_started_ms','snapshot_finished_ms','snapshot_duration_us')
  $sdk=[ordered]@{}
  for($i=0;$i -lt 24;$i++) { $sdk[$sdkNames[$i]]=$w[36+$i] }
  if($latched) {
    Require ($w[4] -eq 1 -and $w[20] -ge 1 -and $w[20] -le 4) 'Invalid Ground first-failure reason'
    Require (($w[24] -band 0xFFFFFFF0L) -eq 0 -and $w[35] -le $w[34]) 'Invalid wrapper flags/byte accounting'
    Require ((U64 $w 30) -ge (U64 $w 28)) 'Backward wrapper clock'
    Require ((U64 $w 60) -ge (U64 $w 30)) 'Failure observation precedes wrapper return'
    if($called) {
      Require ($sdk.schema -eq 1 -and ($sdk.validity_flags -band 0x13) -eq 0x13 -and ($sdk.validity_flags -band 0xFFFFFF00L) -eq 0) 'Incomplete or unknown SDK evidence'
      Require ($sdk.transaction_token -eq $w[22] -and $sdk.attempt_id -eq $w[23]) 'SDK transaction identity mismatch'
      Require ($sdk.terminal_reason -ge 1 -and $sdk.terminal_reason -le 6 -and $sdk.raw_return -le 1) 'Unknown SDK terminal/result'
      Require ($sdk.raw_return -eq (($w[24] -shr 1) -band 1)) 'SDK/wrapper raw bool mismatch'
      Require (($sdk.terminal_reason -eq 1) -eq ($sdk.raw_return -eq 1)) 'Terminal/result contradiction'
      if(($sdk.validity_flags -band 8) -ne 0) {
        Require (($sdk.state_flags -band 0xFFFFC000L) -eq 0 -and ($sdk.flush_blocker_mask -band 0xFFFFFF00L) -eq 0) 'Unknown SDK state/blocker flag'
      } else {
        Require (($sdk.validity_flags -band 128) -eq 0) 'Lockless snapshot cannot be unobserved'
        for($i=48;$i -lt 60;$i++) { Require ($w[$i] -eq 0) 'Unobserved SDK snapshot must be absent' }
      }
      $rawReturn=($sdk.raw_return -eq 1)
    } else {
      Require (($w[24] -band 2) -eq 0 -and $sdk.schema -eq 1) 'Uncalled API cannot claim a return value'
      for($i=37;$i -lt 60;$i++) { Require ($w[$i] -eq 0) 'Uncalled SDK evidence must be absent' }
    }
  } else { for($i=20;$i -lt 62;$i++) { Require ($w[$i] -eq 0) 'Unlatched evidence must be zero' } }
  $terminalNames=@('NotInvoked','Success','NullRing','NullLock','LockTimeout','LoopTimeout','EpochAbort')
  $sdk['snapshot_observed']=($latched -and $called -and ($sdk.validity_flags -band 8) -ne 0)
  $sdk['lock_acquired']=($latched -and $called -and ($sdk.validity_flags -band 4) -ne 0)
  $sdk['terminal_name']=if($latched -and $called){$terminalNames[$sdk.terminal_reason]}else{'NotObserved'}
  $hash=[Security.Cryptography.SHA256]::Create()
  try{$rawSha=([BitConverter]::ToString($hash.ComputeHash($a))).Replace('-','')}finally{$hash.Dispose()}
  $result=[ordered]@{
    schema='vc-lora-r19-first-usb-failure-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false
    raw_size_bytes=384;raw_sha256=$rawSha;sequence=$w[1];record_schema=$w[3];role=$ExpectedRole
    build_fingerprint=@($w[5..8]);boot_instance=@($w[9..12]);failure_latched=$latched
    # U64 JSON strings preserve every bit even in consumers limited to IEEE754.
    clock_sync=[ordered]@{observed=$sync;sync_count=$w[14];nonce=$nonce.ToString();device_us=$syncUs.ToString()}
    first_failure=[ordered]@{reason=$w[20];source_line=$w[21];token=$w[22];attempt_id=$w[23];wrapper_flags=$w[24];api_called=$called;raw_return=$rawReturn;budget_ms=$w[25];expected_epoch=$w[26];observed_epoch=$w[27];started_us=(U64 $w 28).ToString();finished_us=(U64 $w 30).ToString();deadline_us=(U64 $w 32).ToString();failure_observed_us=(U64 $w 60).ToString();elapsed_us=((U64 $w 30)-(U64 $w 28)).ToString();expected_frame_bytes=$w[34];accepted_frame_bytes=$w[35];sdk=$sdk}
    acceptance='NOT_EVALUATED';limitations=@('Stable fixture decoding is not proof of hardware acquisition, host consumption, or communication acceptance.','SDK terminal-boundary snapshot is not continuous state; SnapshotWithoutTxLock does not prove ownership of the pending data.','No PC/device time ordering is inferred without a matched same-boot nonce and explicit uncertainty bounds.','Uncalled API raw_return is unknown, not false.','Boot identity must be generated afresh each firmware startup; a nonzero fixture alone cannot prove entropy.')
  }
  [pscustomobject]$result
}
if($ImportOnly){
  if($DecodeOnly-or$TestOnly-or$FixturePath-or$OutputPath){throw 'ImportOnly forbids all CLI input/output flags'}
  return
}
try {
  if(-not($DecodeOnly-or$TestOnly)){throw 'DecodeOnly or TestOnly is required; live hardware mode does not exist'}
  $f=Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
  if($f.schema-cne'vc-lora-r19-first-usb-failure-fixture-v1'){throw 'Unknown fixture schema'}
  if(-not$f.PSObject.Properties['build_fingerprint']-or-not$f.PSObject.Properties['boot_instance']){throw 'Fixture requires explicit build and boot identity'}
  $result=ConvertFrom-R19FirstUsbFailureBytes -First ([Convert]::FromBase64String($f.first_read_base64)) -Second ([Convert]::FromBase64String($f.second_read_base64)) -ExpectedRole $f.role -ExpectedFingerprint $f.build_fingerprint -ExpectedBoot $f.boot_instance
  $json=$result | ConvertTo-Json -Depth 12
  if($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }
  $json
  exit 0
} catch { Write-Error -ErrorAction Continue ('OFFLINE_DECODE_REJECTED: '+$_.Exception.Message); exit 1 }
