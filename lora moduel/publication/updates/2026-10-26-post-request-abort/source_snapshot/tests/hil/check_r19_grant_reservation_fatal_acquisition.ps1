param([string]$RepoRoot='', [string]$ActualBridgeRawRoot='', [string]$ActualBridgeExecutable='')
$ErrorActionPreference='Stop'
if(!$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0
function Check($ok,$label){$script:checks++;if(!$ok){throw $label}}
function Reject($body,$label){$caught=$false;try{&$body}catch{$caught=$true};Check $caught $label}
. (Join-Path $RepoRoot 'tools/read_r19_grant_reservation_fatal_record.ps1') -ImportOnly
if($ActualBridgeExecutable){
  $ActualBridgeRawRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-fatal-bridge-raw-'+[Guid]::NewGuid().ToString('N'))
  foreach($case in @('repeat-heartbeat','no-new-heartbeat','aux-fault','lease-fault')){
    $out=Join-Path $ActualBridgeRawRoot $case;[void][IO.Directory]::CreateDirectory($out)
    $lines=& $ActualBridgeExecutable $case $out 2>&1
    Check ($LASTEXITCODE-eq0) ('actual pure-host bridge '+$case)
    [IO.File]::WriteAllLines((Join-Path $out 'probe.jsonl'),[string[]]$lines)
  }
}
function Bytes([uint32[]]$words){$bytes=[byte[]]::new(128);for($i=0;$i-lt32;$i++){[BitConverter]::GetBytes($words[$i]).CopyTo($bytes,4*$i)};return ,$bytes}
[uint32[]]$w=[uint32[]]::new(32)
$w[1]=4;$w[2]=0x52314654;$w[3]=1;$w[4]=2
for($i=5;$i-le12;$i++){$w[$i]=[uint32]($i-4)}
$w[13]=7-bor(409-shl8);$w[14]=128;$w[15]=2-bor(13-shl8)-bor(1-shl16)-bor(3-shl24)
$w[16]=37100;$w[18]=39600;$w[20]=37402;$w[22]=15;$w[23]=5050
$w[24]=3;$w[25]=3;$w[26]=3;$w[27]=3;$w[28]=1
$raw=Bytes $w
$decoded=ConvertFrom-R19GrantReservationFatalRecord -First $raw -Second $raw -ExpectedRole vehicle -ExpectedFingerprint $w[5..8] -ExpectedBoot $w[9..12]
Check ($decoded.fatal_latched-and$decoded.reason-eq2-and$decoded.fatal_detail-eq13-and$decoded.observed_ms-ceq'37100') 'exact fatal pre-abort snapshot'
Check (-not$decoded.context.cancellation_available-and$decoded.context.cancellation_phase-eq3-and$decoded.context.cancel_block_reason-eq1-and-not$decoded.context.uart_accepted) 'one-cancel fresh-round context'
Check ($decoded.hold_deadline_ms-ceq'37402'-and$decoded.heartbeat_deadline_ms-ceq'39600'-and$decoded.current_usb_epoch-eq0) 'same-MCU deadlines and epoch0'
Check (-not$decoded.high_speed_start_proven-and-not$decoded.acceptance_authorized) 'diagnostics grant no permission'
foreach($mutation in @('pair','size','magic','schema','role','writer_active','odd','sequence','flags','reason','detail','block','phase','safe_bits','healthy','unknown_predicate','build','boot')){
  [uint32[]]$bad=$w.Clone();[byte[]]$second=$raw.Clone()
  switch($mutation){
    'pair'{$second[100]=$second[100]-bxor1};'size'{$second=[byte[]]::new(127)}
    'magic'{$bad[2]=0x52315354};'schema'{$bad[3]=2};'role'{$bad[4]=1};'writer_active'{$bad[0]=1};'odd'{$bad[1]=3};'sequence'{$bad[1]=6}
    'flags'{$bad[13]=$bad[13]-bor0x80000000};'reason'{$bad[15]=($bad[15]-band0xFFFFFF00)-bor3};'detail'{$bad[15]=($bad[15]-band0xFFFF00FF)-bor(14-shl8)}
    'block'{$bad[15]=($bad[15]-band0xFF00FFFF)-bor(19-shl16)};'phase'{$bad[15]=($bad[15]-band0x00FFFFFF)-bor(4-shl24)}
    'safe_bits'{$bad[22]=$bad[22]-bor0xE00};'healthy'{$bad[22]=12;$bad[15]=$bad[15]-band0xFFFFFF00}
    'unknown_predicate'{$bad[22]=$bad[22]-bor0x1000};'build'{$bad[5]++};'boot'{$bad[9]++}
  }
  $first=Bytes $bad;if($mutation-notin@('pair','size')){$second=$first.Clone()}
  Reject {ConvertFrom-R19GrantReservationFatalRecord -First $first -Second $second -ExpectedRole vehicle -ExpectedFingerprint $w[5..8] -ExpectedBoot $w[9..12]} ('reject '+$mutation)
}
[uint32[]]$unlatched=$w.Clone();$unlatched[1]=2;$unlatched[4]=1;$unlatched[13]=1
foreach($i in 15..31){$unlatched[$i]=0};$bytes=Bytes $unlatched
$ground=ConvertFrom-R19GrantReservationFatalRecord -First $bytes -Second $bytes -ExpectedRole ground
Check (-not$ground.fatal_latched-and$ground.disposition-ceq'NONE') 'Ground initialized no-fatal is valid'
$unlatched[31]=1;$bytes=Bytes $unlatched
Reject {ConvertFrom-R19GrantReservationFatalRecord -First $bytes -Second $bytes} 'unlatched payload must be zero'
if($ActualBridgeRawRoot){
  foreach($case in @('repeat-heartbeat','no-new-heartbeat','aux-fault','lease-fault')){
    [byte[]]$actual=[IO.File]::ReadAllBytes((Join-Path $ActualBridgeRawRoot ($case+'/fatal.bin')))
    $d=ConvertFrom-R19GrantReservationFatalRecord -First $actual -Second $actual -ExpectedRole vehicle
    $expected=@{'repeat-heartbeat'=2;'no-new-heartbeat'=0;'aux-fault'=3;'lease-fault'=4}[$case]
    Check ($d.reason-eq$expected) ('actual bridge raw decoder '+$case)
  }
}
# Verify the reader's actual artifact binding and extract its real OpenOCD
# argument-construction statements, stopping before any native invocation.
$tokens=$null;$errors=$null
$readerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count-eq0) 'actual reader parses'
$readerFunctions=@($readerAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})
foreach($name in @('Assert-R19GrantFatalSelection','Assert-R19ReaderGrantFatalBinding','Get-Sha256','Assert-Hash','Test-ExactDiagnosticInteger','Assert-ExactProperties','Get-OpenOcdLogStage','Convert-TclPath')){
  $f=@($readerFunctions|Where-Object{$_.Name-ceq$name});Check ($f.Count-eq1) ('reader helper '+$name)
  . ([scriptblock]::Create($f[0].Extent.Text))
}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
$readerRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-fatal-reader-plan-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($readerRoot)
$fatalContract=Get-R19GrantReservationFatalCandidateContract -RepoRoot $RepoRoot -Enabled $true
$flag=Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true $true $true $true $true
$fatalSymbol=[pscustomobject]@{name='vc_lora_r19_grant_reservation_fatal_record';address='0x3fcc0000';size_bytes=128;aligned_32_bit=$true}
$roleEntry=[pscustomobject]@{role='vehicle';compile=[pscustomobject]@{argv=@($flag)};runtime_diagnostic_symbols=[pscustomobject]@{symbols=[pscustomobject]@{grant_reservation_fatal=$fatalSymbol}}}
$sourceRows=@('firmware/high_speed/r19_grant_reservation_fatal_record.hpp','tools/read_r19_grant_reservation_fatal_record.ps1')|ForEach-Object{[pscustomobject]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $_) -Algorithm SHA256).Hash;size_bytes=(Get-Item -LiteralPath (Join-Path $RepoRoot $_)).Length}}
$document=[pscustomobject]@{grant_reservation_fatal_diagnostics=$fatalContract;candidate_enable=[pscustomobject]@{property=$flag};canonical_source_snapshot=[pscustomobject]@{files=@($sourceRows)};roles=@($roleEntry)}
$docs=@($document,$document,$document)
$nm='3fcc0000 00000080 B vc_lora_r19_grant_reservation_fatal_record'
$bound=Assert-R19ReaderGrantFatalBinding -Documents $docs -RoleEntry $roleEntry -ExpectedRole vehicle -NmText $nm -RepoRoot $RepoRoot -Requested $true -AgreementRequested $true -StopRequested $true
Check $bound.enabled 'actual reader exact compiled fatal contract'
foreach($mutation in @('unselected','no-agreement','no-stop','D-storage','wrong-size','duplicate-symbol','duplicate-flag','case','float-size')){
  $badDocument=$document|ConvertTo-Json -Depth 25|ConvertFrom-Json;$badDocs=@($badDocument,$badDocument,$badDocument);$badNm=$nm;$requested=$true;$agreement=$true;$stop=$true
  switch($mutation){
    'unselected'{$requested=$false};'no-agreement'{$agreement=$false};'no-stop'{$stop=$false}
    'D-storage'{$badNm=$nm.Replace(' B ',' D ')};'wrong-size'{$badNm=$nm.Replace('00000080','0000007c')};'duplicate-symbol'{$badNm=$nm+"`n"+$nm}
    'duplicate-flag'{$badDocument.roles[0].compile.argv+=@($flag)}
    'case'{$v=$badDocument.grant_reservation_fatal_diagnostics;$badDocument.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$badDocument|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $v}
    'float-size'{$badDocument.roles[0].runtime_diagnostic_symbols.symbols.grant_reservation_fatal.size_bytes=[single]128}
  }
  Reject {Assert-R19ReaderGrantFatalBinding -Documents $badDocs -RoleEntry $badDocument.roles[0] -ExpectedRole vehicle -NmText $badNm -RepoRoot $RepoRoot -Requested $requested -AgreementRequested $agreement -StopRequested $stop} ('actual reader rejects '+$mutation)
}
$live=@($readerFunctions|Where-Object{$_.Name-ceq'Read-LiveStageRecord'})[0]
$planParts=[Collections.Generic.List[string]]::new();$planParts.Add($live.Body.ParamBlock.Extent.Text)
foreach($statement in $live.Body.EndBlock.Statements){
  if($statement-is[Management.Automation.Language.TryStatementAst]){
    foreach($inside in $statement.Body.Statements){
      if($inside.Extent.Text.StartsWith('$script:OpenOcdProcessStarted')){break}
      $planParts.Add($inside.Extent.Text)
    };break
  }
  $planParts.Add($statement.Extent.Text)
}
$planParts.Add('return ,$captureArguments');$actualPlan=[scriptblock]::Create(($planParts-join"`n"))
$ScriptsRoot=$readerRoot;$InterfaceConfig=Join-Path $readerRoot 'interface.cfg';$TargetConfig=Join-Path $readerRoot 'target.cfg'
[IO.File]::WriteAllText($InterfaceConfig,'');[IO.File]::WriteAllText($TargetConfig,'')
$OpenOcdExecutable=$InterfaceConfig;$OpenOcdSha256=Get-Sha256 $OpenOcdExecutable
$InterfaceConfigSha256=Get-Sha256 $InterfaceConfig;$TargetConfigSha256=Get-Sha256 $TargetConfig
$ProbeUsbLocation='OFFLINE-PLAN';$ProbeSerial='OFFLINE-SERIAL';$stageRecordBytes=68;$fifoRecordBytes=112
$artifact=[pscustomobject]@{extended_records_enabled=$true;first_usb_failure_enabled=$true;timed_path_enabled=$true;aux_readiness_enabled=$true;diagnostic_usb_failure_enabled=$true;grant_diagnostics_enabled=$true;grant_reservation_enabled=$true;grant_reservation_stop_enabled=$true;grant_agreement_enabled=$true;grant_reservation_fatal_enabled=$true}
foreach($name in @('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure','timed_path','aux_readiness','diagnostic_usb_failure','grant_diagnostic','grant_reservation','grant_reservation_stop','grant_reservation_fatal')){$artifact|Add-Member NoteProperty ($name+'_address') '0x3fcc0000'}
$arguments=& $actualPlan -Artifact $artifact -OutputDirectory $readerRoot -Attempt 1
$dumps=@($arguments|Where-Object{$_-is[string]-and$_.StartsWith('dump_image ')})
Check ($dumps.Count-eq24-and@($dumps|Where-Object{$_-match'grant-reservation-fatal-attempt-1-(first|second)\.bin.* 128$'}).Count-eq2) 'actual reader constructs24 raw dumps including exact fatal pair'
$artifact.grant_reservation_fatal_enabled=$false;$arguments=& $actualPlan -Artifact $artifact -OutputDirectory $readerRoot -Attempt 1
Check (@($arguments|Where-Object{$_-is[string]-and$_.StartsWith('dump_image ')}).Count-eq22) 'legacy actual reader still constructs22 dumps'
Check (@($arguments|Where-Object{$_-is[string]-and$_-match'^dump_image .*grant-reservation-fatal'}).Count-eq0) 'legacy reader never acquires undeclared fatal record'
$artifact.grant_reservation_fatal_enabled=$true;$artifact.grant_agreement_enabled=$false
Reject {& $actualPlan -Artifact $artifact -OutputDirectory $readerRoot -Attempt 1} 'actual dump construction rejects fatal without agreement before native invocation'
# Import actual production helpers without executing either script's main.
$parentPath=Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$tokens=$null;$errors=$null;$parentAst=[Management.Automation.Language.Parser]::ParseFile($parentPath,[ref]$tokens,[ref]$errors)
Check ($errors.Count-eq0) 'parent parses'
$parentFunctions=@($parentAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})
foreach($name in @('Assert-Condition','Assert-RawProjection','Get-Sha256','Get-GrantReservationFatalRawReplay')){
  $f=@($parentFunctions|Where-Object{$_.Name-ceq$name});Check ($f.Count-eq1) ('actual parent helper '+$name)
  . ([scriptblock]::Create($f[0].Extent.Text))
}
. (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$GrantReservationFatalDiagnostics=$true;$GrantAgreementDiagnostics=$true;$GrantReservationStopDiagnostics=$true
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-fatal-parent-raw-'+[Guid]::NewGuid().ToString('N'))
$evidence=Join-Path $testRoot 'stage_vehicle';[void][IO.Directory]::CreateDirectory($evidence)
$candidate=[pscustomobject]@{artifact_root=(Join-Path $testRoot 'candidate')}
$sealedDecoder=Join-Path $candidate.artifact_root 'evidence/tools/read_r19_grant_reservation_fatal_record.ps1'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $sealedDecoder))
[IO.File]::Copy((Join-Path $repo 'tools/read_r19_grant_reservation_fatal_record.ps1'),$sealedDecoder,$false)
if($ActualBridgeRawRoot){$raw=[IO.File]::ReadAllBytes((Join-Path $ActualBridgeRawRoot 'repeat-heartbeat/fatal.bin'))}
[uint32[]]$actualWords=[uint32[]]::new(32);for($i=0;$i-lt32;$i++){$actualWords[$i]=[BitConverter]::ToUInt32($raw,4*$i)}
[uint32[]]$legacy=[uint32[]]::new(17);for($i=0;$i-lt4;$i++){$legacy[5+$i]=$actualWords[5+$i]}
$first=[pscustomobject]@{boot_instance=[uint32[]]$actualWords[9..12]}
$contract=Get-R19GrantReservationFatalCandidateContract -RepoRoot $repo -Enabled $true
$symbols=[ordered]@{}
foreach($entry in @(@('runtime_stage',68),@('endpoint_fifo',112),@('hwcdc_restart',128),@('ground_usb_commit',128),@('first_usb_failure',384),@('timed_path',512),@('aux_readiness',6144),@('diagnostic_usb_failure',256),@('grant_diagnostic',1024),@('grant_reservation',512),@('grant_reservation_stop',128),@('grant_agreement_capability',4),@('grant_reservation_fatal',128))){
  $key=$entry[0];$name=if($key-ceq'grant_reservation_fatal'){'vc_lora_r19_grant_reservation_fatal_record'}else{'fixture_'+$key}
  $symbols[$key]=[pscustomobject]@{name=$name;address=('0x{0:x8}'-f(0x3fca0000+0x2000*$symbols.Count));size_bytes=$entry[1];aligned_32_bit=$true}
}
$symbol=$symbols.grant_reservation_fatal
$manifest=[pscustomobject]@{grant_reservation_fatal_diagnostics=$contract;canonical_source_snapshot=[pscustomobject]@{files=@([pscustomobject]@{path=$contract.decoder.path;sha256=$contract.decoder.sha256})}}
$sealed=[pscustomobject]@{symbols=[pscustomobject]$symbols}
$decoded=ConvertFrom-R19GrantReservationFatalRecord -First $raw -Second $raw -ExpectedRole vehicle -ExpectedFingerprint $actualWords[5..8] -ExpectedBoot $actualWords[9..12]
$reads=@(1..22|ForEach-Object{[pscustomobject]@{record='existing-record-tested-separately'}})
foreach($sample in 1,2){$suffix=if($sample-eq1){'first'}else{'second'};$path=Join-Path $evidence ('grant_reservation_fatal_'+$suffix+'.bin');[IO.File]::WriteAllBytes($path,$raw);$reads+=,[pscustomobject]@{record='grant_reservation_fatal';sample=$sample;path=$path;size_bytes=128;sha256=Get-Sha256 $path}}
$summary=[pscustomobject]@{schema='vc-lora-r19-runtime-stage-jtag-read-v12';grant_reservation_fatal_required=$true;reads=$reads;binding=[pscustomobject]@{grant_reservation_fatal_diagnostics=$contract;grant_reservation_fatal_address=$symbol.address;artifact=[pscustomobject]@{grant_reservation_fatal_enabled=$true;grant_reservation_fatal_diagnostics=$contract;symbols=[pscustomobject]$symbols}};decoded=[pscustomobject]@{grant_reservation_fatal=$decoded}}
function ReplayFatal {Get-GrantReservationFatalRawReplay -Summary $summary -Role vehicle -EvidenceDirectory $evidence -Manifest $manifest -Sealed $sealed -LegacyWords $legacy -FirstUsbFailure $first}
$replay=ReplayFatal
Check ($replay.fatal_latched-and$replay.reason-eq2-and$replay.context.cancel_block_reason-eq1) 'actual parent replays saved pre-abort raw'
$summary.reads=@($reads[0..21]);Reject {ReplayFatal} '24 to22 missing fatal pair rejected';$summary.reads=$reads
$summary.schema='vc-lora-r19-runtime-stage-jtag-read-v11';Reject {ReplayFatal} 'v11 downgrade rejected';$summary.schema='vc-lora-r19-runtime-stage-jtag-read-v12'
$summary.binding.PSObject.Properties.Remove('grant_reservation_fatal_diagnostics');$summary.binding|Add-Member NoteProperty Grant_Reservation_Fatal_Diagnostics $contract
Reject {ReplayFatal} 'field-case mutation rejected';$summary.binding.PSObject.Properties.Remove('Grant_Reservation_Fatal_Diagnostics');$summary.binding|Add-Member NoteProperty grant_reservation_fatal_diagnostics $contract
$legacy[5]++;Reject {ReplayFatal} 'actual parent fingerprint mismatch rejected';$legacy[5]--
$summary.decoded.grant_reservation_fatal.reason_name='WRONG';Reject {ReplayFatal} 'decoded projection cannot replace raw';$summary.decoded.grant_reservation_fatal.reason_name='HeartbeatDeadlineConflict'
[byte[]]$changed=$raw.Clone();$changed[64]=$changed[64]-bxor1;[IO.File]::WriteAllBytes($reads[23].path,$changed)
Reject {ReplayFatal} 'saved raw/hash mutation rejected';[IO.File]::WriteAllBytes($reads[23].path,$raw)
Check ($null-ne(ReplayFatal)) 'actual parent replay restored'
# Execute the parent's exact final acquisition assignment, with existing
# record conjuncts isolated as in the legacy portable final-gate regression.
$stage=@($parentFunctions|Where-Object{$_.Name-ceq'Get-StageProof'})[0]
$assignment=@($stage.Body.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$proven'-and$n.Right.Extent.Text.Contains('$runtimeStageValid')},$true))[0]
$script:actualFinalGate=[scriptblock]::Create($assignment.Extent.Text)
$gateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tests/hil/check_r19_grant_reservation_stage_final_gate.ps1'),[ref]$tokens,[ref]$errors)
$gate=@($gateAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq'Invoke-ActualFinalGate'})[0].Extent.Text
$gate=$gate.Replace('  $proven=$false',@'
  $summary|Add-Member NoteProperty grant_reservation_fatal_required $true
  $summary|Add-Member NoteProperty reads @(1..24)
  $extendedRawReplay=[pscustomobject]@{raw_read_count=24}
  if($Mutation-ceq'fatal-count'){$summary.reads=@(1..22)}
  if($Mutation-ceq'fatal-required'){$summary.grant_reservation_fatal_required=$false}
  if($Mutation-ceq'fatal-replay-count'){$extendedRawReplay.raw_read_count=22}
  $proven=$false
'@)
. ([scriptblock]::Create($gate))
Check (Invoke-ActualFinalGate 'vc-lora-r19-runtime-stage-jtag-read-v12').proven 'actual parent final24-pair acquisition gate'
foreach($mutation in @('fatal-count','fatal-required','fatal-replay-count','cleanup-proof','native-termination','raw-replay')){Check (-not(Invoke-ActualFinalGate 'vc-lora-r19-runtime-stage-jtag-read-v12' $mutation).proven) ('actual final gate rejects '+$mutation)}
$GrantReservationFatalDiagnostics=$false
Check (-not(Invoke-ActualFinalGate 'vc-lora-r19-runtime-stage-jtag-read-v12').proven) 'new reader cannot downcast to unselected fatal mode'
Write-Output ('parent replay fixture='+$testRoot+' real_bridge_raw='+[bool]$ActualBridgeRawRoot+' previous22record_ABIs_tested_separately=true full_parent_main_executed=false')
Write-Output ('fatal acquisition decoder checks='+$checks+' PASS')
