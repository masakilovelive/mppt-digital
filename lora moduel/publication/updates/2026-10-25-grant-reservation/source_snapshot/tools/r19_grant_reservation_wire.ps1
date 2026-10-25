# Fixed USB-local R19R codec. Definitions only; not RF control or authentication.
function ConvertTo-R19GrantReservationUInt {
  param([object]$Value,[string]$Name,[uint64]$Maximum=[uint64]::MaxValue,[switch]$AllowZero)
  if($null-eq$Value-or$Value-is[bool]-or$Value-is[double]-or$Value-is[single]){throw ('Invalid exact integer '+$Name)}
  $s=[Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture);[uint64]$n=0
  if($s-cnotmatch'^(0|[1-9][0-9]*)$'-or-not[uint64]::TryParse($s,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$n)-or$n-gt$Maximum-or($n-eq0-and-not$AllowZero)){throw ('Invalid canonical integer '+$Name)}
  return $n
}
function Get-R19GrantReservationOpcode {
  param([string]$Name)
  $names=@('','HelloRequest','HelloReply','PrepareVehicle','Prepared','BindGround','BindPeerGround','Bound','BindPeerVehicle','ReleaseVehicle','GroundHeld','TailReady','TailPermitGround','Fault','Started')
  $i=[Array]::IndexOf($names,$Name);if($i-lt1-or$i-eq14){throw 'Unknown or record-only R19R opcode'};return $i
}
function Get-R19GrantReservationCrc {
  param([byte[]]$Bytes)
  if($null-eq$Bytes-or$Bytes.Length-ne66){throw 'R19R requires exactly66 bytes'}
  [uint16]$crc=65535
  foreach($v in @($Bytes[1..63])+@(83)){[uint16]$t=([uint16]$v-bxor($crc-band255));$t=($t-bxor(($t-shl4)-band255))-band255;$crc=(($crc-shr8)-bxor($t-shl8)-bxor($t-shl3)-bxor($t-shr4))-band65535}
  return $crc
}
function New-R19GrantReservationFrame {
  param([Parameter(Mandatory)][string]$Opcode,[Parameter(Mandatory)][ValidateSet('ground','vehicle')][string]$Role,
    [Parameter(Mandatory)][object]$ReaderSession,[Parameter(Mandatory)][object]$SlotNonce,[object]$BootId='0',[object]$UsbEpoch=0,
    [object]$GrantSession=0,[object]$GrantCycle=0,[object]$SlotToken=0,[object]$Generation=0,[object]$DeviceMs=0,[byte]$Flags=0,[byte]$Sequence=0)
  $op=Get-R19GrantReservationOpcode $Opcode
  [uint64]$reader=ConvertTo-R19GrantReservationUInt $ReaderSession 'reader_session'
  [uint64]$nonce=ConvertTo-R19GrantReservationUInt $SlotNonce 'slot_nonce'
  if(($nonce-shr48)-ne0x521B-or($nonce-band[uint64]0x0000FFFFFFFFFFFF)-eq0){throw 'R19R nonce must use fresh521B private domain'}
  [uint64]$boot=ConvertTo-R19GrantReservationUInt $BootId 'boot_id' -AllowZero
  [uint32]$epoch=ConvertTo-R19GrantReservationUInt $UsbEpoch 'usb_epoch' 4294967295 -AllowZero
  [uint16]$session=ConvertTo-R19GrantReservationUInt $GrantSession 'grant_session' 65535 -AllowZero
  [uint16]$cycle=ConvertTo-R19GrantReservationUInt $GrantCycle 'grant_cycle' 65535 -AllowZero
  [uint32]$token=ConvertTo-R19GrantReservationUInt $SlotToken 'slot_token' 4294967295 -AllowZero
  [uint32]$generation=ConvertTo-R19GrantReservationUInt $Generation 'generation' 4294967295 -AllowZero
  [uint32]$ms=ConvertTo-R19GrantReservationUInt $DeviceMs 'device_ms' 4294967295 -AllowZero
  $request=$op-in@(1,3,5,6,8,9,12)
  if(($op-in@(3,4,8,9,11)-and$Role-cne'vehicle')-or($op-in@(5,6,7,10,12)-and$Role-cne'ground')){throw 'R19R opcode/role mismatch'}
  if($Flags-ne0){throw 'R19R flags must be zero; Fault reasons belong to the JTAG record'}
  if($op-eq1){if($boot-ne0-or$epoch-ne0-or$session-ne0-or$cycle-ne0-or$token-ne0-or$generation-ne0-or$ms-ne0){throw 'HelloRequest reserved fields must be zero'}}
  elseif($boot-eq0){throw 'R19R local/peer boot identity cannot be zero'}
  if($op-eq2){if($token-ne0-or$generation-ne0-or($Role-ceq'ground'-and$session-eq0)){throw 'HelloReply Ground requires actual baseline; token/generation reserved'}}
  if($op-eq3){if($session-eq0-or$token-ne0-or$generation-ne0-or$ms-ne0){throw 'PrepareVehicle requires Ground baseline and zero slot fields'}}
  if($op-in@(5,6,8)-and$ms-ne0){throw 'Bind commands cannot carry a device time claim'}
  if($op-in@(4,5,6,7,8,9,10,11,12,14)){if($session-eq0-or$cycle-eq0-or$token-eq0-or$generation-eq0){throw 'R19R reserved slot identity is incomplete'}}
  [byte[]]$b=[byte[]]::new(66);$b[0]=253;$b[1]=54;$b[4]=$Sequence;$b[5]=249;$b[6]=$(if($request){197}else{198});$b[7]=253
  $b[10]=82;$b[11]=49;$b[12]=57;$b[13]=82;$b[14]=1;$b[15]=[byte]$op;$b[16]=$(if($Role-ceq'ground'){1}else{2});$b[17]=$Flags
  foreach($p in @(@(18,$reader,8),@(26,$nonce,8),@(34,$boot,8),@(42,[uint64]$epoch,4),@(46,[uint64]$session,2),@(48,[uint64]$cycle,2),@(50,[uint64]$token,4),@(54,[uint64]$generation,4),@(58,[uint64]$ms,4))){for($i=0;$i-lt$p[2];$i++){$b[[int]$p[0]+$i]=[byte](([uint64]$p[1]-shr(8*$i))-band255)}}
  $b[62]=165;$b[63]=90;[uint16]$crc=Get-R19GrantReservationCrc $b;$b[64]=[byte]($crc-band255);$b[65]=[byte]($crc-shr8);return ,$b
}
function ConvertFrom-R19GrantReservationFrame {
  param([byte[]]$Bytes)
  try{
    if($null-eq$Bytes-or$Bytes.Length-ne66-or$Bytes[0]-ne253-or$Bytes[1]-ne54-or$Bytes[2]-ne0-or$Bytes[3]-ne0-or$Bytes[5]-ne249-or$Bytes[6]-notin@(197,198)-or$Bytes[7]-ne253-or$Bytes[8]-ne0-or$Bytes[9]-ne0-or$Bytes[10]-ne82-or$Bytes[11]-ne49-or$Bytes[12]-ne57-or$Bytes[13]-ne82-or$Bytes[14]-ne1-or$Bytes[62]-ne165-or$Bytes[63]-ne90){throw 'Not canonical R19R namespace'}
    if(([uint16]$Bytes[64]-bor([uint16]$Bytes[65]-shl8))-ne(Get-R19GrantReservationCrc $Bytes)){throw 'R19R CRC mismatch'}
    $names=@('','HelloRequest','HelloReply','PrepareVehicle','Prepared','BindGround','BindPeerGround','Bound','BindPeerVehicle','ReleaseVehicle','GroundHeld','TailReady','TailPermitGround','Fault','Started')
    if($Bytes[15]-lt1-or$Bytes[15]-gt13){throw 'Unknown or record-only R19R opcode'}
    $role=if($Bytes[16]-eq1){'ground'}elseif($Bytes[16]-eq2){'vehicle'}else{throw 'Unknown R19R role'}
    $values=@{}
    foreach($p in @(@('ReaderSession',18,8),@('SlotNonce',26,8),@('BootId',34,8),@('UsbEpoch',42,4),@('GrantSession',46,2),@('GrantCycle',48,2),@('SlotToken',50,4),@('Generation',54,4),@('DeviceMs',58,4))){[uint64]$v=0;for($i=0;$i-lt$p[2];$i++){$v=$v-bor([uint64]$Bytes[[int]$p[1]+$i]-shl(8*$i))};$values[$p[0]]=$v.ToString([Globalization.CultureInfo]::InvariantCulture)}
    [byte[]]$canonical=New-R19GrantReservationFrame -Opcode $names[$Bytes[15]] -Role $role -Flags $Bytes[17] -Sequence $Bytes[4] @values
    for($i=0;$i-lt66;$i++){if($canonical[$i]-ne$Bytes[$i]){throw 'R19R component/opcode noncanonical bytes'}}
    [pscustomobject]@{schema='vc-lora-r19-grant-reservation-usb-v1';valid=$true;opcode=$names[$Bytes[15]];opcode_number=[int]$Bytes[15];role=$role;flags=[int]$Bytes[17]
      reader_session=$values.ReaderSession;slot_nonce=$values.SlotNonce;boot_id=$values.BootId;usb_epoch=$values.UsbEpoch;grant_session=$values.GrantSession;grant_cycle=$values.GrantCycle;slot_token=$values.SlotToken;generation=$values.Generation;device_ms=$values.DeviceMs;sequence=[int]$Bytes[4];component=[int]$Bytes[6];error=''}
  }catch{[pscustomobject]@{schema='vc-lora-r19-grant-reservation-usb-v1';valid=$false;opcode='';role='';error=$_.Exception.Message}}
}
function New-R19GrantReservationParser {
  [pscustomobject]@{buffer=[Collections.Generic.List[byte]]::new();next_raw_offset=0L;buffer_raw_offset=0L;input_bytes=0L;accepted_frames=0;invalid_namespace_frames=0}
}
function Add-R19GrantReservationBytes {
  param([object]$Parser,[byte[]]$Bytes,[long]$RawOffset,[string]$ReadCompletedTicks)
  if($null-eq$Bytes-or$Bytes.Length-gt8192-or$Parser.buffer.Count+$Bytes.Length-gt16384-or$RawOffset-ne$Parser.next_raw_offset){throw 'R19R parser prefix/capacity mismatch'}
  foreach($v in $Bytes){$Parser.buffer.Add($v)};$Parser.input_bytes+=$Bytes.Length;$Parser.next_raw_offset+=$Bytes.Length;$found=[Collections.Generic.List[object]]::new()
  while($Parser.buffer.Count-gt0){
    $b=$Parser.buffer
    if($b[0]-ne253-and$b[0]-ne254){$b.RemoveAt(0);$Parser.buffer_raw_offset++;continue}
    $header=if($b[0]-eq253){10}else{6};if($b.Count-lt$header){break}
    $length=$header+[int]$b[1]+2;if($b[0]-eq253-and($b[2]-band1)-ne0){$length+=13};if($b.Count-lt$length){break}
    $namespace=$b[0]-eq253-and$b[5]-eq249-and$b[6]-in@(197,198)-and$b[7]-eq253-and$b[8]-eq0-and$b[9]-eq0
    if($namespace){
      [byte[]]$frame=$b.GetRange(0,$length).ToArray();$d=ConvertFrom-R19GrantReservationFrame $frame
      if($d.valid){$found.Add([pscustomobject]@{kind='GrantReservation';read_completed_ticks=$ReadCompletedTicks;raw_offset=$Parser.buffer_raw_offset;bytes=$frame;decoded=$d});$Parser.accepted_frames++}
      else{$Parser.invalid_namespace_frames++}
    }
    # Skip complete declared MAVLink frames, including unknown payloads. Never
    # promote an embedded R19R-shaped payload into a top-level control command.
    $b.RemoveRange(0,$length);$Parser.buffer_raw_offset+=$length
  }
  return ,$found.ToArray()
}
