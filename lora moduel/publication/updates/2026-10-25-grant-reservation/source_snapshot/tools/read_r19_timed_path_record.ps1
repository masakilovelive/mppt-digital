# Pure decoder only. Dot-sourcing this file never opens a device or starts a process.
function ConvertFrom-R19TimedPathRecord {
  [CmdletBinding()]
  param([Parameter(Mandatory)][byte[]]$First,[Parameter(Mandatory)][byte[]]$Second,
    [Parameter(Mandatory)][ValidateSet('ground','vehicle')][string]$ExpectedRole,
    [Parameter(Mandatory)][ValidateSet('SyncOnly','ExplicitHostArm')][string]$ExpectedMode)
  if($First.Length-ne512-or$Second.Length-ne512){throw 'Timed path requires two exact 512-byte records'}
  for($i=0;$i-lt512;$i++){if($First[$i]-ne$Second[$i]){throw 'Timed path record is not stable'}}
  [uint32[]]$w=New-Object uint32[] 128
  for($i=0;$i-lt128;$i++){$w[$i]=[BitConverter]::ToUInt32($First,$i*4)}
  if($w[0]-ne0-or($w[1]-band1)-ne0-or$w[1]-eq0-or$w[2]-ne0x52313954-or$w[3]-ne1){throw 'Timed path writer/seqlock/magic/schema invalid'}
  $role=switch($w[4]){1{'ground'}2{'vehicle'}default{throw 'Timed path role invalid'}}
  $mode=switch($w[14]){1{'SyncOnly'}2{'ExplicitHostArm'}default{throw 'Timed path mode invalid'}}
  if($role-cne$ExpectedRole-or$mode-cne$ExpectedMode){throw 'Timed path role/mode does not match sealed candidate'}
  $flags=$w[13]
  if(($flags-band1)-eq0-or($flags-band0xFFFFFC00)-ne0-or($flags-band192)-eq192){throw 'Timed path flags invalid'}
  if((($flags-band8)-ne0-and$w[24]-ne106)-or(($flags-band8)-eq0-and$w[24]-ne0)){throw 'Timed path product 106 ms budget invalid'}
  foreach($i in @(51,54,55,56,57)){if($w[$i]-ne0){throw 'Timed path reserved word is nonzero'}}
  if(($w[46]-band0xFFFFFF00L)-ne0-or($w[47]-band0xFFFFC000L)-ne0-or($w[49]-band0xFFFFFF00L)-ne0-or$w[48]-gt6){throw 'Timed path SDK flags/reason are unknown'}
  foreach($stage in @(@(2,16,17,18,19,52,53),@(4,26,27),@(8,20,21,24,28,29,40,41),@(16,22,30,31),@(32,32,33,42,43,44,45,46,47,48,49,50),@(128,23,36,37,38,39))){
    if(($flags-band[uint32]$stage[0])-eq0){foreach($i in $stage[1..($stage.Count-1)]){if($w[$i]-ne0){throw 'Timed path data exists without its observed stage'}}}
  }
  if(($flags-band192)-eq0-and($w[34]-ne0-or$w[35]-ne0)){throw 'Timed path terminal time exists without terminal stage'}
  if(($flags-band32)-ne0-and(($flags-band16)-eq0-or($w[46]-band8)-eq0-or$w[48]-eq0)){throw 'Timed path SDK snapshot is not terminal-boundary observed'}
  if(($w[9]-bor$w[10]-bor$w[11]-bor$w[12])-eq0){throw 'Timed path boot identity is zero'}
  if($w[21]-gt280-or$w[22]-gt$w[21]-or$w[23]-gt4){throw 'Timed path byte/reason accounting invalid'}
  if(($flags-band8)-ne0-and($w[21]-lt21-or($First[232]-ne0xFD-and$First[232]-ne0xFE))){throw 'Timed path first frame is not a complete-size MAVLink candidate'}
  if(($flags-band8)-eq0-and($w[21]-ne0-or$w[22]-ne0)){throw 'Timed path frame accounting exists without enqueue'}
  if(($flags-band16)-ne0-and($flags-band8)-eq0){throw 'Timed path acceptance has no enqueue'}
  if(($flags-band192)-ne0-and($flags-band16)-eq0){throw 'Timed path terminal has no accepted event'}
  if(($flags-band64)-ne0-and($w[22]-ne$w[21]-or$w[23]-ne0)){throw 'Timed path completion is inconsistent'}
  if(($flags-band128)-ne0-and$w[23]-eq0){throw 'Timed path failure reason is absent'}
  for($i=232+[int]$w[21];$i-lt512;$i++){if($First[$i]-ne0){throw 'Timed path frame padding is nonzero'}}
  function U64([int]$Offset){return ([uint64]$w[$Offset]+([uint64]$w[$Offset+1]*[uint64]4294967296)).ToString([Globalization.CultureInfo]::InvariantCulture)}
  $times=[ordered]@{arm_us=U64 26;enqueue_us=U64 28;accepted_us=U64 30;sdk_snapshot_us=U64 32;terminal_us=U64 34;failure_started_us=U64 36;failure_returned_us=U64 38;deadline_us=U64 40;clock_request_us=U64 52}
  if(($flags-band4)-ne0-and($flags-band2)-eq0){throw 'Timed path ARM has no session identity'}
  if(($flags-band2)-ne0-and((U64 16)-eq'0'-or(U64 18)-eq'0')){throw 'Timed path session identity is zero'}
  if(($flags-band768)-eq0){
    if(($flags-band8)-ne0-and($flags-band4)-ne0-and[uint64]$times.enqueue_us-lt[uint64]$times.arm_us){throw 'Timed path enqueue precedes ARM'}
    if(($flags-band16)-ne0-and[uint64]$times.accepted_us-lt[uint64]$times.enqueue_us){throw 'Timed path acceptance precedes enqueue'}
    if(($flags-band192)-ne0-and[uint64]$times.terminal_us-lt[uint64]$times.accepted_us){throw 'Timed path terminal precedes acceptance'}
  }
  [byte[]]$frame=New-Object byte[] ([int]$w[21]);if($frame.Length-gt0){[Array]::Copy($First,232,$frame,0,$frame.Length)}
  $sha=[Security.Cryptography.SHA256]::Create();try{$frameSha=([BitConverter]::ToString($sha.ComputeHash($frame))).Replace('-','')}finally{$sha.Dispose()}
  return [pscustomobject][ordered]@{
    schema='vc-lora-r19-timed-path-record-v1';schema_version=1;size_bytes=512;sequence=$w[1]
    role=$role;mode=$mode;mode_value=$w[14];build_id=@($w[5..8]);boot_id=@($w[9..12]);flags=$flags
    usb_epoch=$w[15];observed_epoch=$w[25];reader_session=U64 16;nonce=U64 18;token=$w[20]
    frame_bytes=$w[21];accepted_bytes=$w[22];failure_reason=$w[23];product_budget_ms=$w[24]
    initialized=$true;session_observed=(($flags-band2)-ne0);arm_accepted=(($flags-band4)-ne0)
    identity_mismatch=(($flags-band256)-ne0);clock_regressed=(($flags-band512)-ne0)
    frame_enqueued=(($flags-band8)-ne0);hwcdc_accepted_observed=(($flags-band16)-ne0)
    sdk_snapshot_observed=(($flags-band32)-ne0);usb_completed=(($flags-band64)-ne0);usb_failed=(($flags-band128)-ne0)
    timestamps=$times;raw_frame_base64=[Convert]::ToBase64String($frame);frame_sha256=$frameSha
    sdk=[pscustomobject][ordered]@{publish_generation=$w[42];pickup_generation=$w[43];ring_bytes=$w[44];stash_bytes=$w[45];validity=$w[46];state=$w[47];terminal=$w[48];blocker_mask=$w[49];attempt=$w[50];terminal_sample_valid=(($w[46]-band8)-ne0)}
    root_cause_proven=$false;acceptance_authorized=$false;deployment_authorized=$false
    limitations=@('Stable committed MCU record only; not a continuous physical FIFO or PC consumption proof.','MAVLink CRC and PC/MCU bounded time correlation require independent evaluator input.')
  }
}
