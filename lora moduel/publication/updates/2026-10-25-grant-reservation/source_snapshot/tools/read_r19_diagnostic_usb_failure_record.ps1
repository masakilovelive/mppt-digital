[CmdletBinding()]
param([switch]$ImportOnly,[switch]$DecodeOnly,[switch]$TestOnly,
  [string]$FixturePath,[string]$OutputPath)
# Pure definitions on import: no hardware, process inventory, clock, or I/O.
function ConvertFrom-R19DiagnosticUsbFailureRecord {
  param([byte[]]$First,[byte[]]$Second,
    [ValidateSet('ground','vehicle')][string]$ExpectedRole,
    [AllowNull()][object[]]$ExpectedFingerprint,[AllowNull()][object[]]$ExpectedBoot)
  $ErrorActionPreference='Stop'
  Set-StrictMode -Version Latest
  function Require([bool]$v,[string]$message){if(-not$v){throw $message}}
  function U64([uint32[]]$w,[int]$n){[uint64]$w[$n]+[uint64]$w[$n+1]*[uint64]4294967296}
  function Identity([object[]]$expected,[uint32[]]$w,[int]$offset){
    Require (@($expected).Count-eq4) 'Identity requires four uint32 words'
    for($n=0;$n-lt4;$n++){
      [decimal]$value=$expected[$n]
      Require ($value-ge0-and$value-le[uint32]::MaxValue-and$value-eq[math]::Floor($value)) 'Invalid identity word'
      Require ([uint32]$value-eq$w[$offset+$n]) 'Identity mismatch'
    }
  }
  Require ($ExpectedRole-ceq'ground'-or$ExpectedRole-ceq'vehicle') 'Unknown expected role'
  Require ($null-ne$First-and$null-ne$Second-and$First.Length-eq256-and$Second.Length-eq256) 'Record size must be exactly256 bytes'
  for($n=0;$n-lt256;$n++){Require ($First[$n]-eq$Second[$n]) 'Two reads differ'}
  [uint32[]]$w=[uint32[]]::new(64)
  for($n=0;$n-lt64;$n++){$w[$n]=[BitConverter]::ToUInt32($First,4*$n)}
  Require ($w[0]-eq0-and($w[1]-band1)-eq0) 'Unstable seqlock sample'
  Require ($w[2]-eq0x44313955-and$w[3]-eq1) 'Unknown record magic/schema'
  $roleCode=if($ExpectedRole-ceq'ground'){1}else{2}
  Require ($w[4]-eq$roleCode) 'Role mismatch'
  if($null-ne$ExpectedFingerprint){Identity $ExpectedFingerprint $w 5}
  if($null-ne$ExpectedBoot){Identity $ExpectedBoot $w 9}
  Require (($w[9]-bor$w[10]-bor$w[11]-bor$w[12])-ne0) 'Zero boot identity'
  Require (($w[13]-band1)-ne0-and($w[13]-band0xFFFFFFFCL)-eq0) 'Unknown or uninitialized flags'
  for($n=58;$n-lt64;$n++){Require ($w[$n]-eq0) 'Reserved words must be zero'}
  $latched=($w[13]-band2)-ne0
  $called=($w[23]-band1)-ne0
  $raw=($w[23]-band2)-ne0
  $context=($w[23]-band16)-ne0
  $rawReturn=$null
  [string[]]$names=@('schema','validity_flags','transaction_token','attempt_id',
    'terminal_reason','timeout_ms','expected_loss_epoch','started_ms','finished_ms',
    'lock_wait_ms','elapsed_ms','raw_return','state_flags','observed_loss_epoch',
    'ring_pending_bytes','stash_pending_bytes','publish_generation','pickup_generation',
    'raw_interrupt_status','interrupt_enable_mask','flush_blocker_mask',
    'snapshot_started_ms','snapshot_finished_ms','snapshot_duration_us')
  $sdk=[ordered]@{}
  for($n=0;$n-lt24;$n++){$sdk[$names[$n]]=$w[32+$n]}
  $sdkAbsent=$true
  for($n=33;$n-le55;$n++){if($w[$n]-ne0){$sdkAbsent=$false}}
  if($latched){
    Require ($w[14]-ge1-and$w[14]-le30-and$w[16]-le3-and$w[17]-le255) 'Unknown diagnostic reason/action/sequence'
    Require (($w[18]-band0xFFFFFFF0L)-eq0-and($w[23]-band0xFFFFFFE0L)-eq0) 'Unknown bootstrap/wrapper flags'
    Require ($w[57]-le$w[56]) 'Accepted bytes exceed frame size'
    Require ((U64 $w 28)-ge(U64 $w 26)-and(U64 $w 24)-ge(U64 $w 28)) 'Backward MCU timestamps'
    if(($w[23]-band8)-ne0){Require ((U64 $w 30)-ne0-and(U64 $w 28)-le(U64 $w 30)) 'False within-deadline witness'}
    Require ($called-or(-not$raw-and-not$context)) 'Uncalled API cannot claim result/context'
    Require ($sdk.schema-eq1) 'Unknown SDK evidence schema'
    if(-not$called){Require $sdkAbsent 'Uncalled API SDK evidence must be absent'}
    elseif($sdkAbsent){Require (-not$context) 'Absent SDK cannot match current call'}
    else{
      Require (($sdk.validity_flags-band0x13)-eq0x13-and($sdk.validity_flags-band0xFFFFFF00L)-eq0) 'Incomplete or unknown SDK evidence'
      Require ($sdk.terminal_reason-ge1-and$sdk.terminal_reason-le6-and$sdk.raw_return-le1) 'Unknown SDK terminal/result'
      Require (($sdk.terminal_reason-eq1)-eq($sdk.raw_return-eq1)) 'SDK terminal/result contradiction'
      if(($sdk.validity_flags-band8)-ne0){
        Require (($sdk.state_flags-band0xFFFFC000L)-eq0-and($sdk.flush_blocker_mask-band0xFFFFFF00L)-eq0) 'Unknown FIFO state/wait reason'
      }else{
        Require (($sdk.validity_flags-band128)-eq0) 'Lockless snapshot cannot be unobserved'
        for($n=44;$n-le55;$n++){Require ($w[$n]-eq0) 'Unobserved SDK snapshot must be absent'}
      }
      if($context){
        Require ($sdk.transaction_token-eq$w[17]+1-and$sdk.attempt_id-eq$w[22]-and$sdk.timeout_ms-eq$w[21]-and$sdk.expected_loss_epoch-eq$w[19]) 'SDK context mismatch'
        Require ($sdk.raw_return-eq$(if($raw){1}else{0})) 'SDK/wrapper raw result mismatch'
      }
    }
    if($called){$rawReturn=$raw}
  }else{for($n=14;$n-le57;$n++){Require ($w[$n]-eq0) 'Unlatched evidence must be zero'}}
  $sdkObserved=$latched-and$called-and-not$sdkAbsent
  $snapshotObserved=$sdkObserved-and($sdk.validity_flags-band8)-ne0
  $sdk['call_context_matches']=$context
  $sdk['snapshot_observed']=[bool]$snapshotObserved
  $sdk['lock_acquired']=[bool]($sdkObserved-and($sdk.validity_flags-band4)-ne0)
  $sdk['matching_terminal_snapshot']=[bool]($context-and$snapshotObserved)
  $terminalNames=@('NotObserved','Success','NullRing','NullLock','LockTimeout','LoopTimeout','EpochAbort')
  $sdk['terminal_name']=if($sdkObserved){$terminalNames[$sdk.terminal_reason]}else{'NotObserved'}
  if(-not$sdkObserved){$sdk['raw_return']=$null}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=([BitConverter]::ToString($sha.ComputeHash($First))).Replace('-','')}finally{$sha.Dispose()}
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-diagnostic-usb-failure-decoded-v1';result='PASS';mode='offline-only'
    hardware_interaction=$false;raw_size_bytes=256;raw_sha256=$hash;record_schema=$w[3]
    sequence=$w[1];role=$ExpectedRole;build_fingerprint=@($w[5..8]);boot_instance=@($w[9..12])
    expected_identity_bound=[bool]($null-ne$ExpectedFingerprint-and$null-ne$ExpectedBoot)
    failure_latched=$latched
    first_failure=[ordered]@{
      reason=$w[14];source_line=$w[15];action=$w[16];diagnostic_sequence=$w[17]
      bootstrap_flags=$w[18];expected_epoch=$w[19];observed_epoch=$w[20];budget_ms=$w[21]
      attempt_id=$w[22];wrapper_flags=$w[23];api_called=$called;raw_return=$rawReturn
      sdk_context_matches=$context;failure_observed_us=(U64 $w 24).ToString()
      started_us=(U64 $w 26).ToString();finished_us=(U64 $w 28).ToString();deadline_us=(U64 $w 30).ToString()
      expected_frame_bytes=$w[56];accepted_frame_bytes=$w[57];sdk=$sdk
    }
    physical_fifo_fault_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@(
      'Immutable diagnostic terminal-call evidence, not the product Heartbeat384-byte record or a later live FIFO snapshot.',
      'A nonmatching/absent SDK context is unknown for the failed transaction and cannot locate a physical FIFO fault.',
      'SnapshotWithoutTxLock records observed shared state without proving caller ownership.',
      'MCU64 timestamps and SDK millis32 are distinct; no PC/MCU ordering or guaranteed offset is inferred.',
      'Stable decoding alone cannot prove hardware acquisition provenance, host receipt, RF delivery, or product acceptance.'
    )
  }
}
if($ImportOnly){
  if($DecodeOnly-or$TestOnly-or$FixturePath-or$OutputPath){throw 'ImportOnly forbids CLI inputs and outputs'}
  return
}
try{
  if(-not($DecodeOnly-or$TestOnly)){throw 'DecodeOnly or TestOnly required; no live hardware mode exists'}
  $f=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
  if($f.schema-cne'vc-lora-r19-diagnostic-usb-failure-fixture-v1'){throw 'Unknown fixture schema'}
  if(-not$f.PSObject.Properties['build_fingerprint']-or-not$f.PSObject.Properties['boot_instance']){throw 'CLI fixture requires explicit fingerprint and boot'}
  $d=ConvertFrom-R19DiagnosticUsbFailureRecord -First ([Convert]::FromBase64String($f.first_read_base64)) -Second ([Convert]::FromBase64String($f.second_read_base64)) -ExpectedRole $f.role -ExpectedFingerprint $f.build_fingerprint -ExpectedBoot $f.boot_instance
  $json=$d|ConvertTo-Json -Depth 12
  if($OutputPath){$json|Set-Content -LiteralPath $OutputPath -Encoding utf8}
  $json
  exit 0
}catch{Write-Error -ErrorAction Continue ('OFFLINE_DECODE_REJECTED: '+$_.Exception.Message);exit 1}
