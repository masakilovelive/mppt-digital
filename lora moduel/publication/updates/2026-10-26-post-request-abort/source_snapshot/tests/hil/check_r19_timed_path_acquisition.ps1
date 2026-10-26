[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=if($RepoRoot){(Resolve-Path -LiteralPath $RepoRoot).Path}else{Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $root 'tools/r19_timed_path_acquisition.ps1') -ImportOnly
$script:checks=0
function Check([bool]$Value,[string]$Name){if(-not$Value){throw "FAIL: $Name"};$script:checks++}
function Reject([scriptblock]$Code,[string]$Name){$failed=$false;try{&$Code|Out-Null}catch{$failed=$true};Check $failed $Name}
function Clone-R19Fixture($Value){$Value|ConvertTo-Json -Depth 50|ConvertFrom-Json}
function Hex([byte[]]$Bytes){Get-R19AcquisitionSha256 $Bytes}
$nonce=([long]0x5219000000000001).ToString([Globalization.CultureInfo]::InvariantCulture)
[byte[]]$reply=New-R19TimesyncRequest -Nonce ([long]$nonce)
$reply[6]=194;[BitConverter]::GetBytes([long]1000000000).CopyTo($reply,10)
[BitConverter]::GetBytes([uint16](Get-R19TimesyncCrc $reply)).CopyTo($reply,26)
[byte[]]$ready=New-R19HostReadinessFrame -Opcode Ready -Role Ground -ReaderSession 9 -Nonce $nonce -BootId 5 -UsbEpoch 0 -ReplyDeviceUs 1000000
$p=New-R19TimedPathPrivateParser -Nonce $nonce
$partial=Add-R19TimedPathPrivateBytes $p ([byte[]]$reply[0..10]) '100'
Check ($partial.Count-eq0) 'split clock reply stays incomplete'
$observed=Add-R19TimedPathPrivateBytes $p ([byte[]]$reply[11..27]) '110'
Check ($observed.Count-eq1-and$observed[0].kind-ceq'ClockReply'-and$observed[0].read_completed_ticks-ceq'110') 'reply completion ties to final native read'
$observed=Add-R19TimedPathPrivateBytes $p $ready '120'
Check ($observed.Count-eq1-and$observed[0].kind-ceq'Ready') 'ready canonical'
[byte[]]$bad=$ready.Clone();$bad[65]=$bad[65]-bxor1
Check ((Add-R19TimedPathPrivateBytes $p $bad '130').Count-eq0) 'bad CRC not accepted'
$p=New-R19TimedPathPrivateParser -Nonce $nonce
[byte[]]$combined=@(0,1,2)+$reply+$ready
Check ((Add-R19TimedPathPrivateBytes $p $combined '140').Count-eq2) 'noise and both private frames'
Reject {New-R19TimedPathPrivateParser -Nonce '1'} 'nonce restricted'
$p=New-R19TimedPathPrivateParser -Nonce $nonce
Reject {Add-R19TimedPathPrivateBytes $p ([byte[]]::new(8193)) '1'} 'parser bounded'
$now=[DateTime]::UtcNow
$permit=[pscustomobject]@{schema='vc-lora-r19-timed-path-execution-permit-v1';status='AUTHORIZED_SINGLE_CAPTURE';candidate_id='candidate-test';mode='ExplicitHostArm';handoff_sha256=('A'*64);flash_evidence_sha256=('B'*64);issued_utc=$now.AddSeconds(-1).ToString('o');expires_utc=$now.AddSeconds(60).ToString('o');safety_confirmed=$true;one_time=$true;restore_required=$true;capture_seconds=40;ports=@([pscustomobject]@{role='vehicle';port='COM3';baud=115200;pnp_instance_id='USB\\VEHICLE';usb_parent_instance_id='USB\\PARENT_V'},[pscustomobject]@{role='ground';port='COM6';baud=57600;pnp_instance_id='USB\\GROUND';usb_parent_instance_id='USB\\PARENT_G'})}
Check ((Test-R19TimedPathExecutionPermit -Permit $permit -Mode ExplicitHostArm -CandidateId 'candidate-test' -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now).valid) 'explicit bounded one-time permit'
foreach($field in @('safety_confirmed','one_time','restore_required')){$x=Clone-R19Fixture $permit;$x.$field=$false;Reject {Test-R19TimedPathExecutionPermit -Permit $x -Mode ExplicitHostArm -CandidateId candidate-test -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} "permit $field required"}
$x=Clone-R19Fixture $permit;$x.expires_utc=$now.AddSeconds(-1).ToString('o');Reject {Test-R19TimedPathExecutionPermit -Permit $x -Mode ExplicitHostArm -CandidateId candidate-test -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'expired rejected'
$x=Clone-R19Fixture $permit;$x.ports[0].port='COM6';Reject {Test-R19TimedPathExecutionPermit -Permit $x -Mode ExplicitHostArm -CandidateId candidate-test -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'role port duplicates rejected'
$x=Clone-R19Fixture $permit;$x.capture_seconds=41;Reject {Test-R19TimedPathExecutionPermit -Permit $x -Mode ExplicitHostArm -CandidateId candidate-test -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'capture above40 rejected'
$x=Clone-R19Fixture $permit;Reject {Test-R19TimedPathExecutionPermit -Permit $x -Mode SyncOnly -CandidateId candidate-test -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'mode mix rejected'
$contract=[pscustomobject]@{schema='vc-lora-r19-timed-path-candidate-v1';enabled=$true;mode='ExplicitHostArm';mode_value=2;record=[pscustomobject]@{symbol='vc_lora_r19_timed_path_record';size_bytes=512;schema_version=1}}
$handoff=[pscustomobject]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';runtime_fail_diagnostics_enabled=$true;artifact_id='candidate-test';timed_path_diagnostics=$contract}
$flash=[pscustomobject]@{schema='vc-lora-r19-candidate-flash-evidence-v1';result='PASS';status='PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY';candidate=[pscustomobject]@{handoff_sha256=('A'*64)};one_run_hil_authorized=$true;timed_path_diagnostics=$contract;roles=@([pscustomobject]@{role='vehicle';port='COM3';pnp_device_id=$permit.ports[0].pnp_instance_id;parent_device_id=$permit.ports[0].usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true},[pscustomobject]@{role='ground';port='COM6';pnp_device_id=$permit.ports[1].pnp_instance_id;parent_device_id=$permit.ports[1].usb_parent_instance_id;write_pass=$true;verify_pass=$true;reenumeration_pass=$true})}
Check ((Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $flash -Permit $permit -Mode ExplicitHostArm -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now).valid) 'mode-bound flash/handoff plan'
$f=Clone-R19Fixture $flash;$f.roles[0].verify_pass=$false;Reject {Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $f -Permit $permit -Mode ExplicitHostArm -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'failed readback blocks all acquisition'
$f=Clone-R19Fixture $flash;$f.roles[0].pnp_device_id='DIFFERENT';Reject {Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $f -Permit $permit -Mode ExplicitHostArm -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'permit must bind same flash device identity'
$f=Clone-R19Fixture $flash;$f.timed_path_diagnostics.enabled='false';Reject {Get-R19TimedPathCapturePlan -Handoff $handoff -FlashEvidence $f -Permit $permit -Mode ExplicitHostArm -HandoffSha256 ('A'*64) -FlashEvidenceSha256 ('B'*64) -NowUtc $now} 'flash enabled flag must be boolean true'
$text=Get-Content -Raw -LiteralPath (Join-Path $root 'tools/run_r19_timed_path_capture.ps1')
Check ($text.Contains('if($ImportOnly)')) 'runner importonly before execution'
Check ($text.Contains('ContinuousReader')-and$text.Contains('WaitReady')) 'prearmed native single reader'
Check (-not$text.Contains('DiscardInBuffer')-and-not$text.Contains('DiscardOutBuffer')) 'never purges buffers'
Check (-not$text.Contains('PARAM_REQUEST')-and-not$text.Contains('COMMAND_LONG')) 'no product requests generated'
Check ($text.Contains('CloseAndStop')-and$text.Contains('finally')) 'cleanup covers failures'
Check ($text.Contains('CreateNew')-and$text.Contains('.consumed')) 'atomic permit consumption'
Check ($text.Contains('Get-R19TimedPathCapturePlan')) 'pure plan validates source-bound contract'

# Normalization is driven by exact saved bytes, not a manually claimed frame.
[byte[]]$hb=[byte[]]::new(21);$hb[0]=253;$hb[1]=9;$hb[4]=7;$hb[5]=1;$hb[6]=1;$hb[18]=3
# Recalculate using canonical X25: keep fixture independent of the validator.
[uint16]$crc=65535
foreach($value in @($hb[1..18])+@(50)){$tmp=($value-bxor($crc-band255));$tmp=($tmp-bxor(($tmp-shl4)-band255))-band255;$crc=(($crc-shr8)-bxor($tmp-shl8)-bxor($tmp-shl3)-bxor($tmp-shr4))-band65535}
$hb[19]=[byte]($crc-band255);$hb[20]=[byte](($crc-shr8)-band255)
Check (Test-R19TimedPathHeartbeat $hb) 'fixture heartbeat CRC'
[byte[]]$raw=@(4,5)+$reply+$ready+$hb
$wf=[pscustomobject]@{reply_read_validated=$true;reply=[pscustomobject]@{nonce=$nonce;device_microseconds='1000000'};ready_binding_validated=$true;arm_write_accepted=$true;ready=[pscustomobject]@{reader_session='9';usb_epoch=0;boot_id='5'}}
[byte[]]$txRequest=New-R19TimesyncRequest -Nonce ([long]$nonce)
$decodedReady=ConvertFrom-R19HostReadinessFrame $ready
[byte[]]$txArm=New-R19HostReadinessArm -Ready $decodedReady -ReplyReadValidated $true -ContinuousReader $true
$writes=@([pscustomobject]@{kind='ClockRequest';started_ticks='110';returned_ticks='120';base64=[Convert]::ToBase64String($txRequest);sha256=(Hex $txRequest);accepted_bytes=28;clock_domain_id='shared-QPC';frequency='10000000'},[pscustomobject]@{kind='Arm';started_ticks='301';returned_ticks='310';base64=[Convert]::ToBase64String($txArm);sha256=(Hex $txArm);accepted_bytes=66;clock_domain_id='shared-QPC';frequency='10000000'})
$ground=[pscustomobject]@{role='ground';reader_continuous=$true;overflow=$false;clock_domain_id='shared-QPC';frequency='10000000';nonce=$nonce;read_started_ticks='100';raw_base64=[Convert]::ToBase64String($raw);raw_bytes=$raw.Length;raw_sha256=(Hex $raw);blocks=@([pscustomobject]@{offset=0;count=96;begin_ticks='100';end_ticks='300';clock_domain_id='shared-QPC';frequency='10000000'},[pscustomobject]@{offset=96;count=21;begin_ticks='310';end_ticks='400';clock_domain_id='shared-QPC';frequency='10000000'});workflow=$wf;writes=$writes;product_observations=@([pscustomobject]@{raw_offset=96;frame_bytes=21;frame_sha256=(Hex $hb);read_completed_ticks='400';validation_ticks='420';clock_domain_id='shared-QPC';frequency='10000000'})}
$capture=[pscustomobject]@{schema='vc-lora-r19-timed-path-capture-v1';result='CAPTURE_COMPLETE_OBSERVATIONS_ONLY';cleanup_proven=$true;candidate_id='test';mode='ExplicitHostArm';capture_seconds=40;clock_domain_id='shared-QPC';frequency='10000000';roles=@($ground)}
$record=[pscustomobject]@{schema='vc-lora-r19-timed-path-record-v1';schema_version=1;flags=191;size_bytes=512;role='ground';mode='ExplicitHostArm';build_id=@(1,2,3,4);boot_id=@(5,0,6,7);usb_epoch=0;observed_epoch=0;reader_session='9';nonce=$nonce;token=1;frame_enqueued=$true;session_observed=$true;arm_accepted=$true;hwcdc_accepted_observed=$true;sdk_snapshot_observed=$true;usb_completed=$false;usb_failed=$true;raw_frame_base64=[Convert]::ToBase64String($hb);frame_bytes=$hb.Length;frame_sha256=(Hex $hb);accepted_bytes=21;product_budget_ms=106;failure_reason=1;timestamps=[pscustomobject]@{clock_request_us='1000000';arm_us='1000100';enqueue_us='1000200';accepted_us='1000300';sdk_snapshot_us='1106600';terminal_us='1106700';failure_started_us='1000500';failure_returned_us='1106500'};sdk=[pscustomobject]@{publish_generation=3;pickup_generation=2;ring_bytes=0;stash_bytes=0}}
$normalized=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)
Check ($normalized.evaluation.pc_frame_validated-and$normalized.evaluation.observed_stages-ccontains'MCU_USB_FAILED') 'later PC CRC observation cannot erase local failure'
Check (-not$normalized.evaluation.clock_bounds_valid-and-not$normalized.evaluation.root_cause_proven-and-not$normalized.evaluation.acceptance_eligible) 'no invented clock bound or root cause'
Check ($normalized.evaluation.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM') 'versioned clear same MCU clock record establishes ARM-relative order only'
Check ($normalized.evidence.events[-1].timestamp-ceq'420') 'PC event uses actual runtime CRC validation QPC, not earlier native read return'
Check (($normalized.evidence.events|Where-Object{$_.kind-ceq'MCU_USB_FAILED'}).timestamp-ceq'1106500') 'failure event is original API return, not later record observation'
Check (($normalized.evidence.events|Where-Object{$_.kind-ceq'MCU_USB_PUBLISHED'}).timestamp-ceq'1106600') 'SDK snapshot retains later observation timestamp'
$r=Clone-R19Fixture $record;$r.accepted_bytes=0
$n=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)
Check ($n.evaluation.pc_frame_validated) 'software accepted zero not physical zero'
foreach($field in @('raw_bytes','raw_sha256')){$c=Clone-R19Fixture $capture;if($field-eq'raw_bytes'){$c.roles[0].$field++}else{$c.roles[0].$field='D'*64};Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} "raw $field mismatch rejected"}
$c=Clone-R19Fixture $capture;$c.roles[0].blocks[0].offset=1;Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'raw offset gap rejected'
$c=Clone-R19Fixture $capture;$c.roles[0].blocks[0].clock_domain_id='different';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'each native block clock provenance bound'
$c=Clone-R19Fixture $capture;$c.roles[0].blocks[0].frequency='1000000';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'each native block frequency bound'
$c=Clone-R19Fixture $capture;$c.roles[0].workflow.ready.boot_id='99';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'wire READY boot bound to full MCU boot record'
$c=Clone-R19Fixture $capture;$c.roles[0].read_started_ticks='999';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'read start cannot follow saved bytes'
$r=Clone-R19Fixture $record;$r.frame_enqueued=$false;$r.session_observed=$false;$n=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)
Check ($n.evaluation.classification-ceq'TRACE_INCOMPLETE'-and-not$n.evaluation.trace_complete) 'missing frame/session remains partial, not a pass'
$r=Clone-R19Fixture $record;$r.nonce=([long]0x5219000000000002).ToString();Reject {ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)} 'cross-session nonce rejected'
$r=Clone-R19Fixture $record;$r.observed_epoch=1;Reject {ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)} 'epoch discontinuity rejected'
$r=Clone-R19Fixture $record;$r.frame_sha256='E'*64;Reject {ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)} 'MCU frame SHA exact'
$r=Clone-R19Fixture $record;$r.mode='SyncOnly';Reject {ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)} 'mode-specific raw decoder input'
$c=Clone-R19Fixture $capture;[byte[]]$fakeRaw=$raw.Clone();$fakeRaw[28]=$fakeRaw[28]-bxor1;$c.roles[0].raw_base64=[Convert]::ToBase64String($fakeRaw);$c.roles[0].raw_sha256=Hex $fakeRaw;Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'handshake assertions cannot replace raw matching CRC reply'
$c=Clone-R19Fixture $capture;$c.roles[0].writes[1].base64=[Convert]::ToBase64String($txRequest);$c.roles[0].writes[1].sha256=Hex $txRequest;Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'ARM requires exact canonical raw OUT bytes'
$c=Clone-R19Fixture $capture;$c.roles[0].writes[1].started_ticks='200';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'ARM before matching READY read cannot bind'
$r=Clone-R19Fixture $record;$r.flags=$r.flags-bor512;$n=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)
Check (-not$n.evaluation.trace_complete-and-not$n.evaluation.mcu_clock_continuity_verified) 'sticky clock regression taints record coverage'
$r=Clone-R19Fixture $record;$r.flags=$r.flags-bor256;$n=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)
Check (-not$n.evaluation.trace_complete) 'sticky identity taint never becomes complete trace'
[byte[]]$signed=[byte[]]::new(34);[Array]::Copy($hb,$signed,21);$signed[2]=1
$crc=65535;foreach($value in @($signed[1..18])+@(50)){$tmp=($value-bxor($crc-band255));$tmp=($tmp-bxor(($tmp-shl4)-band255))-band255;$crc=(($crc-shr8)-bxor($tmp-shl8)-bxor($tmp-shl3)-bxor($tmp-shr4))-band65535};$signed[19]=[byte]($crc-band255);$signed[20]=[byte](($crc-shr8)-band255)
$r=Clone-R19Fixture $record;$r.raw_frame_base64=[Convert]::ToBase64String($signed);$r.frame_sha256=Hex $signed;$r.frame_bytes=34
$n=ConvertTo-R19TimedPathEvidence -Capture $capture -DeviceRecord $r -CandidateId test -DeviceRecordSha256 ('C'*64)
Check ($n.binding_status-ceq'UNSUPPORTED_SIGNED_HEARTBEAT_PARTIAL'-and-not$n.evaluation.acceptance_eligible-and-not$n.evaluation.trace_complete) 'legal unsupported signed frame is partial, not a hardware failure'
$ledger=[Collections.Generic.List[object]]::new();$script:fakeTicks=100
Reject {Invoke-R19TimedPathPrivateWrite -Kind ClockRequest -Bytes $txRequest -Ledger $ledger -ClockDomainId fake-qpc -Frequency '10000000' -NowTicks {$script:fakeTicks++;[string]$script:fakeTicks} -Writer {param($bytes) throw 'injected write timeout'}} 'write timeout propagated after preserving raw attempt'
Check ($ledger.Count-eq1-and$ledger[0].write_success-eq$false-and$null-eq$ledger[0].accepted_bytes-and$ledger[0].sha256-ceq(Hex $txRequest)-and$ledger[0].returned_ticks-ceq'102') 'failed private write retains exact source bytes and no invented acceptance'
$w=Invoke-R19TimedPathPrivateWrite -Kind ClockRequest -Bytes $txRequest -Ledger $ledger -ClockDomainId fake-qpc -Frequency '10000000' -NowTicks {$script:fakeTicks++;[string]$script:fakeTicks} -Writer {param($bytes)}
Check ($w.write_success-and$w.accepted_bytes-eq28-and$ledger.Count-eq2) 'local successful private write ledger'
Reject {Invoke-R19TimedPathPrivateWrite -Kind ClockRequest -Bytes $hb -Ledger $ledger -ClockDomainId fake-qpc -Frequency '10000000' -NowTicks {'100'} -Writer {throw 'must not reach writer'}} 'writer rejects product bytes under private label'
$c=Clone-R19Fixture $capture;$c.roles[0].product_observations[0].clock_domain_id='second-clock';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'runtime CRC validation clock separately bound'
$c=Clone-R19Fixture $capture;$c.roles[0].product_observations[0].validation_ticks='399';Reject {ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)} 'CRC validation cannot precede final-byte native return'
$c=Clone-R19Fixture $capture;$c.roles[0].product_observations=@();$n=ConvertTo-R19TimedPathEvidence -Capture $c -DeviceRecord $record -CandidateId test -DeviceRecordSha256 ('C'*64)
Check (-not$n.evaluation.pc_frame_validated) 'offline CRC alone cannot invent a runtime validation event'
$hp=New-R19TimedPathHeartbeatParser
Check ((Add-R19TimedPathHeartbeatBytes -Parser $hp -Bytes ([byte[]]$hb[0..10]) -RawOffset 0 -ReadCompletedTicks '200' -ClockDomainId qpc -Frequency '10000000' -SampleValidationTicks {'205'}).Count-eq0) 'partial product frame has no runtime CRC flag'
$hpResult=Add-R19TimedPathHeartbeatBytes -Parser $hp -Bytes ([byte[]]$hb[11..20]) -RawOffset 11 -ReadCompletedTicks '210' -ClockDomainId qpc -Frequency '10000000' -SampleValidationTicks {'215'}
Check ($hpResult.Count-eq1-and$hpResult[0].raw_offset-eq0-and$hpResult[0].validation_ticks-ceq'215'-and$hpResult[0].read_completed_ticks-ceq'210') 'runtime CRC ledger retains independent read and validation samples'
Write-Output "PASS: $script:checks checks"
