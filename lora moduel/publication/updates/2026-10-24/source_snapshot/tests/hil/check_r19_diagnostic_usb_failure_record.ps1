param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:checks=0
function Check([bool]$v,[string]$name){if(-not$v){throw "FAIL $name"};$script:checks++}
. (Join-Path $RepoRoot 'tools/read_r19_diagnostic_usb_failure_record.ps1') -ImportOnly
function Bytes([uint32[]]$w){[byte[]]$b=[byte[]]::new(256);for($i=0;$i-lt64;$i++){[Array]::Copy([BitConverter]::GetBytes($w[$i]),0,$b,4*$i,4)};return ,$b}
function SetU64([uint32[]]$w,[int]$n,[uint64]$v){$w[$n]=[uint32]($v-band[uint64]4294967295);$w[$n+1]=[uint32]($v-shr32)}
function Decode([uint32[]]$w){[byte[]]$b=Bytes $w;ConvertFrom-R19DiagnosticUsbFailureRecord -First $b -Second $b -ExpectedRole ground -ExpectedFingerprint @(1,2,3,4) -ExpectedBoot @(5,6,7,8)}
function Reject([uint32[]]$w,[string]$name){$rejected=$false;try{$null=Decode $w}catch{$rejected=$true};Check $rejected $name}
[uint32[]]$w=[uint32[]]::new(64)
$w[1]=2;$w[2]=0x44313955;$w[3]=1;$w[4]=1
for($i=0;$i-lt4;$i++){$w[5+$i]=[uint32](1+$i);$w[9+$i]=[uint32](5+$i)}
$w[13]=1
$init=Decode $w
Check (-not$init.failure_latched-and$init.raw_size_bytes-eq256) 'unlatched initialized record'
$w[1]=4;$w[13]=3;$w[14]=16;$w[15]=5037;$w[16]=2;$w[17]=1
$w[19]=7;$w[20]=7;$w[21]=100;$w[22]=5;$w[23]=21
SetU64 $w 26 9007199254741101
SetU64 $w 28 9007199254841102
SetU64 $w 30 9007199254841101
SetU64 $w 24 9007199254841114
$w[32]=1;$w[33]=127;$w[34]=2;$w[35]=5;$w[36]=5;$w[37]=100;$w[38]=7
$w[39]=4294967280;$w[40]=84;$w[42]=100;$w[44]=0x2417;$w[45]=7
$w[46]=31;$w[47]=1;$w[48]=8;$w[49]=7;$w[52]=0x1c;$w[53]=84;$w[54]=84;$w[55]=5
$w[56]=63;$w[57]=63
$d=Decode $w
Check ($d.failure_latched-and$d.first_failure.sdk_context_matches-and$d.first_failure.sdk.matching_terminal_snapshot) 'matching terminal SDK evidence'
Check ($d.first_failure.started_us-ceq'9007199254741101'-and$d.first_failure.failure_observed_us-ceq'9007199254841114') 'uint64 timestamps preserve exact decimal strings'
Check ($d.first_failure.sdk.terminal_name-ceq'LoopTimeout'-and$d.first_failure.sdk.ring_pending_bytes-eq31-and$d.first_failure.sdk.flush_blocker_mask-eq28) 'exact first failure wait/queue snapshot retained'
Check (-not$d.acceptance_authorized-and-not$d.deployment_authorized-and-not$d.physical_fifo_fault_proven) 'decoder cannot grant physical proof or acceptance'
foreach($change in @(@(0,1),@(1,5),@(2,0),@(3,2),@(4,2),@(13,7),@(14,0),@(14,31),@(16,4),@(17,256),@(18,16),@(23,53),@(34,3),@(35,6),@(37,99),@(38,8),@(33,383),@(36,7),@(43,1),@(44,0x4000),@(52,256),@(57,64),@(58,1),@(63,1))){$bad=[uint32[]]$w.Clone();$bad[$change[0]]=[uint32]$change[1];Reject $bad "reject changed word $($change[0])=$($change[1])"}
$bad=[uint32[]]$w.Clone();$bad[23]=29;Reject $bad 'reject false within-deadline witness'
$bad=[uint32[]]$w.Clone();SetU64 $bad 28 1;Reject $bad 'reject backward MCU return'
$bad=[uint32[]]$w.Clone();SetU64 $bad 24 1;Reject $bad 'reject observation preceding return'
$bad=[uint32[]]$w.Clone();$bad[33]=119;Reject $bad 'reject absent SDK snapshot with nonzero payload'
$bad=[uint32[]]$w.Clone();$bad[23]=5;$bad[34]=99;$bad[35]=99
$stale=Decode $bad
Check (-not$stale.first_failure.sdk_context_matches-and-not$stale.first_failure.sdk.matching_terminal_snapshot) 'stale context retained but cannot locate current failure'
$bad=[uint32[]]$w.Clone();$bad[23]=0;for($i=32;$i-le55;$i++){$bad[$i]=0};$bad[32]=1
$uncalled=Decode $bad
Check ($null-eq$uncalled.first_failure.raw_return-and-not$uncalled.first_failure.sdk.snapshot_observed-and$uncalled.first_failure.sdk.terminal_name-ceq'NotObserved') 'uncalled API return and snapshot unknown'
$bad[23]=2;Reject $bad 'uncalled API cannot claim return'
$bad[23]=1
$unknown=Decode $bad
Check (-not$unknown.first_failure.sdk_context_matches-and-not$unknown.first_failure.sdk.snapshot_observed) 'called API with absent call-local SDK remains unknown'
$bad=[uint32[]]$w.Clone();$bad[13]=1;Reject $bad 'unlatched record cannot expose stale evidence'
[byte[]]$b=Bytes $w;$different=[byte[]]$b.Clone();$different[60]=$different[60]-bxor1
$rejected=$false;try{$null=ConvertFrom-R19DiagnosticUsbFailureRecord -First $b -Second $different -ExpectedRole ground}catch{$rejected=$true};Check $rejected 'two unequal reads rejected'
$rejected=$false;try{$null=ConvertFrom-R19DiagnosticUsbFailureRecord -First $b[0..254] -Second $b -ExpectedRole ground}catch{$rejected=$true};Check $rejected 'wrong size rejected'
$rejected=$false;try{$null=ConvertFrom-R19DiagnosticUsbFailureRecord -First $b -Second $b -ExpectedRole ground -ExpectedBoot @(5,6,7,9)}catch{$rejected=$true};Check $rejected 'boot mismatch rejected'
$rejected=$false;try{$null=ConvertFrom-R19DiagnosticUsbFailureRecord -First $b -Second $b -ExpectedRole ground -ExpectedFingerprint @(1,2,3,9)}catch{$rejected=$true};Check $rejected 'fingerprint mismatch rejected'
$w[4]=2;[byte[]]$vb=Bytes $w
$vehicle=ConvertFrom-R19DiagnosticUsbFailureRecord -First $vb -Second $vb -ExpectedRole vehicle
Check ($vehicle.role-ceq'vehicle'-and$vehicle.failure_latched-and-not$vehicle.expected_identity_bound) 'Vehicle supported with explicit unbound optional identity'
$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
$reader=Get-Content -LiteralPath $readerPath -Raw
Check ($reader.Contains('vc-lora-r19-runtime-stage-jtag-read-v8')-and$reader.Contains('diagnostic_usb_failure_first')) 'reader v8 must retain two eighth-record samples'
Check ($reader.Contains('Get-R19RuntimeRecordEffectiveMode')) 'versioned Vehicle mode must not change legacy semantics'
Check ($reader.Contains('ConvertFrom-R19DiagnosticUsbFailureRecord -First $diagnosticUsbFirstBytes -Second $diagnosticUsbSecondBytes -ExpectedRole $expectedRole -ExpectedFingerprint $legacy.build_fingerprint -ExpectedBoot $legacy.boot_instance')) 'eighth decoder joins exact legacy build and boot'
# Exercise the real offline v8 entry point with all eight binary records. No
# native/OpenOCD implementation is evaluated by the fixture-only invocation.
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-diagnostic-v8-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
$shellPath=if($PSVersionTable.PSEdition-ceq'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
function Pack([uint32[]]$words){[byte[]]$bytes=[byte[]]::new($words.Count*4);for($i=0;$i-lt$words.Count;$i++){[BitConverter]::GetBytes($words[$i]).CopyTo($bytes,4*$i)};return ,$bytes}
function NewV8Fixture([string]$Role='ground'){
  [uint32]$roleCode=if($Role-ceq'ground'){1}else{2}
  [uint32[]]$build=@(0x52313944,0x53544731,0x32303236,0x31303033)
  [uint32[]]$stage=@(0,24,0x52313953,1,$roleCode,0x52313944,0x53544731,0x32303236,0x31303033,0x7fff,1,11,2,3,0,0,0)
  [uint32[]]$fifo=@(0,40,0x48313946,2,15,2,2,64,0,32,3,2,2,2,2,0,2,2,0,1,0,0,0x80,0,2,1,0,0)
  [uint32[]]$restart=[uint32[]]::new(32);$restart[1]=2;$restart[2]=0x48313952;$restart[3]=1;$restart[4]=1
  [uint32[]]$commit=[uint32[]]::new(32);$commit[1]=2;$commit[2]=0x52313943;$commit[3]=1;$commit[4]=$roleCode
  for($i=0;$i-lt4;$i++){$commit[5+$i]=$build[$i]}
  $records=[ordered]@{runtime_stage=(Pack $stage);endpoint_fifo=(Pack $fifo);hwcdc_restart=(Pack $restart);ground_usb_commit=(Pack $commit)}
  foreach($spec in @(@('first_usb_failure',96,0x52313955),@('timed_path',128,0x52313954),@('diagnostic_usb_failure',64,0x44313955))){
    [uint32[]]$words=[uint32[]]::new([int]$spec[1]);$words[1]=2;$words[2]=[uint32]$spec[2];$words[3]=1;$words[4]=$roleCode;$words[13]=1
    for($i=0;$i-lt4;$i++){$words[5+$i]=$build[$i];$words[9+$i]=[uint32](1+$i)}
    if($spec[0]-ceq'timed_path'){$words[14]=if($Role-ceq'ground'){2}else{1}}
    $records[$spec[0]]=Pack $words
  }
  [uint32[]]$aux=[uint32[]]::new(1536)
  [uint32[]]$magics=@(0x5231414f,0x52314145,0x52315552)
  for($section=0;$section-lt3;$section++){$offset=$section*512;$aux[$offset+1]=2;$aux[$offset+2]=$magics[$section];$aux[$offset+3]=1;$aux[$offset+4]=$roleCode;$aux[$offset+13]=1;for($i=0;$i-lt4;$i++){$aux[$offset+5+$i]=$build[$i];$aux[$offset+9+$i]=[uint32](1+$i)}}
  $aux[512+16]=120;$records['aux_readiness']=Pack $aux
  $sources=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1')|ForEach-Object{[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $_) -Algorithm SHA256).Hash}}
  $f=[ordered]@{schema='vc-lora-r19-usb-extended-jtag-fixture-v8';reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';artifact_id='offline-diagnostic-v8';role=$Role
    canonical_source_snapshot=[ordered]@{files=@($sources)}
    usb_role_capabilities=[ordered]@{schema='vc-lora-r19-usb-role-capabilities-v1';mode='ExplicitHostArm';implementation_bound=$true;canonical_sources=@($sources);roles=@(
      [ordered]@{role='vehicle';clock_request_reply=$true;effective_mode='SyncOnly';ready=$false;arm=$false},[ordered]@{role='ground';clock_request_reply=$true;effective_mode='ExplicitHostArm';ready=$true;arm=$true})}
    diagnostic_usb_failure_diagnostics=[ordered]@{schema='vc-lora-r19-diagnostic-usb-failure-candidate-v1';enabled=$true;macro='VC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD';reader_schema='vc-lora-r19-runtime-stage-jtag-read-v8';record=[ordered]@{symbol='vc_lora_r19_diagnostic_usb_failure_record';schema_version=1;size_bytes=256};decoder=[ordered]@{path='tools/read_r19_diagnostic_usb_failure_record.ps1';sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot 'tools/read_r19_diagnostic_usb_failure_record.ps1') -Algorithm SHA256).Hash}}}
  $addresses=@{runtime_stage='0x3fcab000';endpoint_fifo='0x3fcab100';hwcdc_restart='0x3fcab200';ground_usb_commit='0x3fcab300';first_usb_failure='0x3fcab400';timed_path='0x3fcab600';aux_readiness='0x3fcac000';diagnostic_usb_failure='0x3fcad800'}
  foreach($name in $records.Keys){$f[$name+'_address']=$addresses[$name];$f[$name+'_first_read_base64']=[Convert]::ToBase64String($records[$name]);$f[$name+'_second_read_base64']=$f[$name+'_first_read_base64']}
  return $f
}
function ChangeFixtureWord($f,[string]$Record,[int]$Index,[uint32]$Value,[switch]$FirstOnly){foreach($sample in @('first','second')){if($FirstOnly-and$sample-ceq'second'){continue};$key=$Record+'_'+$sample+'_read_base64';$bytes=[Convert]::FromBase64String($f[$key]);[BitConverter]::GetBytes($Value).CopyTo($bytes,4*$Index);$f[$key]=[Convert]::ToBase64String($bytes)}}
function RunV8([string]$Name,$Fixture,[bool]$Pass){
  $caseRoot=Join-Path $fixtureRoot $Name;[void](New-Item -ItemType Directory -Path $caseRoot)
  $path=Join-Path $caseRoot 'fixture.json';$Fixture|ConvertTo-Json -Depth 18|Set-Content -LiteralPath $path -Encoding utf8
  & $shellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $readerPath -OfflineExtendedRecordFixtureOnly -FixturePath $path -OutputRoot (Join-Path $caseRoot 'read') *> (Join-Path $caseRoot 'reader.log')
  $code=$LASTEXITCODE;$summary=Get-Content -LiteralPath (Join-Path $caseRoot 'read/summary.json') -Raw|ConvertFrom-Json
  Check $(if($Pass){$code-eq0-and$summary.result-ceq'PASS'-and@($summary.reads).Count-eq16-and$summary.schema-ceq'vc-lora-r19-usb-extended-offline-read-v8'}else{$code-ne0-and$summary.result-ceq'FAIL'}) $Name
  return $summary
}
$groundV8=RunV8 'ground-eight-record-positive' (NewV8Fixture) $true
Check ($groundV8.decoded.timed_path.mode-ceq'ExplicitHostArm'-and$groundV8.decoded.diagnostic_usb_failure.expected_identity_bound-and-not$groundV8.hardware_interaction) 'Ground effective mode and strict cross-record identity'
$vehicleV8=RunV8 'vehicle-eight-record-positive' (NewV8Fixture 'vehicle') $true
Check ($vehicleV8.decoded.timed_path.mode-ceq'SyncOnly'-and$vehicleV8.decoded.diagnostic_usb_failure.role-ceq'vehicle') 'Vehicle SyncOnly effective mode does not claim ARM'
foreach($mutation in @('reader-downgrade','fixture-downgrade','missing-second','size','overlap','different-read','new-boot','timed-boot','aux-boot','vehicle-global-mode','vehicle-privilege','canonical-binding','decoder-pin','missing-capabilities','missing-contract')){
  $f=NewV8Fixture 'vehicle'
  switch($mutation){
    'reader-downgrade'{$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v7'}
    'fixture-downgrade'{$f.schema='vc-lora-r19-usb-extended-jtag-fixture-v2'}
    'missing-second'{$f.Remove('diagnostic_usb_failure_second_read_base64')}
    'size'{$f.diagnostic_usb_failure_first_read_base64=[Convert]::ToBase64String([byte[]]::new(252))}
    'overlap'{$f.diagnostic_usb_failure_address='0x3fcad7fc'}
    'different-read'{ChangeFixtureWord $f 'diagnostic_usb_failure' 1 4 -FirstOnly}
    'new-boot'{ChangeFixtureWord $f 'diagnostic_usb_failure' 9 99}
    'timed-boot'{ChangeFixtureWord $f 'timed_path' 9 99}
    'aux-boot'{ChangeFixtureWord $f 'aux_readiness' 9 99}
    'vehicle-global-mode'{ChangeFixtureWord $f 'timed_path' 14 2}
    'vehicle-privilege'{$f.usb_role_capabilities.roles[0].ready=$true}
    'canonical-binding'{$f.canonical_source_snapshot.files[0]=[ordered]@{path=$f.canonical_source_snapshot.files[0].path;sha256='0'*64}}
    'decoder-pin'{$f.diagnostic_usb_failure_diagnostics.decoder.sha256='0'*64}
    'missing-capabilities'{$f.Remove('usb_role_capabilities')}
    'missing-contract'{$f.Remove('diagnostic_usb_failure_diagnostics')}
  }
  $null=RunV8 ('reject-'+$mutation) $f $false
}
# Import definitions only; fake native capture writes fixture bytes and logs.
# This path cannot invoke a real native executable or enumerate hardware.
$parseTokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($readerPath,[ref]$parseTokens,[ref]$parseErrors)
Check (@($parseErrors).Count-eq0) 'reader AST parses'
$mockFunctions=@('Read-LiveStageRecord','Assert-Hash','Get-Sha256','Convert-TclPath','Get-OpenOcdLogStage','Assert-SmpCaptureLog','Assert-SmpCurstate','Assert-SmpHaltedCurstate','Assert-SmpRunningCurstate','Get-R19RuntimeRecordEffectiveMode')
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-in$mockFunctions}){. ([scriptblock]::Create($node.Extent.Text))}
$legacyArtifact=[pscustomobject]@{diagnostic_usb_failure_enabled=$false;timed_path_diagnostics=[pscustomobject]@{mode='ExplicitHostArm'}}
Check ((Get-R19RuntimeRecordEffectiveMode $legacyArtifact 'vehicle')-ceq'ExplicitHostArm') 'legacy v6/v7 Vehicle retains global mode interpretation'
$mockFixture=NewV8Fixture
$mockArtifact=[pscustomobject]@{extended_records_enabled=$true;first_usb_failure_enabled=$true;timed_path_enabled=$true;aux_readiness_enabled=$true;diagnostic_usb_failure_enabled=$true}
foreach($name in @('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure','timed_path','aux_readiness','diagnostic_usb_failure')){$mockArtifact|Add-Member NoteProperty ($name+'_address') $mockFixture[$name+'_address']}
$mockRoot=Join-Path $fixtureRoot 'mock-capture';[void](New-Item -ItemType Directory -Path $mockRoot)
$ScriptsRoot=$mockRoot;$OpenOcdExecutable=$readerPath;$OpenOcdSha256=Get-Sha256 $readerPath
$InterfaceConfig=$readerPath;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$readerPath;$TargetConfigSha256=$OpenOcdSha256
$ProbeSerial='mock-offline-only';$ProbeUsbLocation='1-1.1';$stageRecordBytes=68;$fifoRecordBytes=112
function Invoke-NativeProcessCapture {
  param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
  Check (@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1) 'mock capture exactly one SMP halt'
  $command=$Arguments-join"`n";$matches=[regex]::Matches($command,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
  Check ($matches.Count-eq16) 'mock capture preserves all sixteen raw reads'
  Check ($command.IndexOf('VC_LORA_JTAG_IDENTITY_MATCHED')-lt$command.IndexOf("`nhalt`n")-and$command.LastIndexOf('dump_image')-lt$command.IndexOf('catch { resume }')) 'all sixteen reads follow identity and share same halt boundary'
  $names=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure','timed_path','aux_readiness','diagnostic_usb_failure')
  for($ordinal=0;$ordinal-lt16;$ordinal++){$m=$matches[$ordinal];$name=$names[$ordinal%8];$sample=if($ordinal-lt8){'first'}else{'second'};$bytes=[Convert]::FromBase64String($mockFixture[$name+'_'+$sample+'_read_base64']);Check ([int]$m.Groups[3].Value-eq$bytes.Length-and$m.Groups[2].Value-ceq$mockFixture[$name+'_address']) ('mock exact size/address '+$name+' '+$sample);[IO.File]::WriteAllBytes($m.Groups[1].Value,$bytes)}
  @('VC_LORA_JTAG_OPEN_SERIAL=mock-offline-only','VC_LORA_JTAG_OPEN_LOCATION=1-1.1','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')|Set-Content -LiteralPath $LogPath
  return [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
}
function Invoke-OpenOcdCleanup {return [pscustomobject]@{required=$true;attempted=$true;exit_code=0;process_termination_proven=$true;resume_shutdown_proven=$true}}
$mockRaw=Read-LiveStageRecord -Artifact $mockArtifact -OutputDirectory $mockRoot -Attempt 1
Check ($mockRaw.smp_capture_proven-and$mockRaw.cleanup.resume_shutdown_proven-and$mockRaw.diagnostic_usb_failure_first.Length-eq256-and$mockRaw.diagnostic_usb_failure_second.Length-eq256) 'v8 paired eighth record retained with SMP resume proof in mock'
# Bind a complete sealed candidate mock as well as decoding raw fixtures. The
# NM implementation is an in-process PowerShell fixture, never a hardware tool.
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]}){. ([scriptblock]::Create($node.Extent.Text))}
$repo=$RepoRoot;$OutputRoot=Join-Path $fixtureRoot 'sealed';[void](New-Item -ItemType Directory -Path $OutputRoot)
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1'),[ref]$parseTokens,[ref]$parseErrors)
foreach($node in $fixtureAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-in@('New-Candidate','New-FirstFailureCandidate','Save-Candidate','Json-Write')}){. ([scriptblock]::Create($node.Extent.Text))}
$auxAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tests/hil/check_r19_aux_readiness_artifact.ps1'),[ref]$parseTokens,[ref]$parseErrors)
foreach($node in $auxAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq'New-AuxCandidate'}){. ([scriptblock]::Create($node.Extent.Text))}
foreach($pair in @(@('R19FirstFailureDecoderPath','read_r19_first_usb_failure_record.ps1'),@('R19TimedPathDecoderPath','read_r19_timed_path_record.ps1'),@('R19AuxReadinessDecoderPath','read_r19_aux_readiness_record.ps1'),@('R19DiagnosticUsbFailureDecoderPath','read_r19_diagnostic_usb_failure_record.ps1'))){Set-Variable -Scope Script -Name $pair[0] -Value (Join-Path $RepoRoot ('tools/'+$pair[1]))}
$NmExecutable=Join-Path $OutputRoot 'mock-nm.ps1';[IO.File]::WriteAllText($NmExecutable,'param($a,$b,$c);Get-Content (Join-Path $PSScriptRoot ''nm.txt'');$global:LASTEXITCODE=0');$NmSha256=Get-Sha256 $NmExecutable
$nmEight=@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record','3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab600 00000200 B vc_lora_r19_timed_path_record','3fcac000 00001800 B vc_lora_r19_aux_readiness_record','3fcad800 00000100 B vc_lora_r19_diagnostic_usb_failure_record')-join"`n"
function NewV8Candidate([string]$Name){
  $candidate=New-AuxCandidate $Name;$f=NewV8Fixture
  foreach($doc in @($candidate.manifest,$candidate.seal,$candidate.handoff)){$doc.reader_schema=$f.reader_schema;$doc.diagnostic_usb_failure_diagnostics=$f.diagnostic_usb_failure_diagnostics;$doc.usb_role_capabilities=$f.usb_role_capabilities;$doc.roles[0].runtime_diagnostic_symbols.symbols.diagnostic_usb_failure=[ordered]@{name='vc_lora_r19_diagnostic_usb_failure_record';address='0x3fcad800';size_bytes=256;aligned_32_bit=$true}}
  $flag=(Get-R19CandidateCompileProperty $true ExplicitHostArm $true)+' -DVC_LORA_R19_DIAGNOSTIC_USB_FAILURE_RECORD=1';$candidate.manifest.candidate_enable.property=$flag;$candidate.manifest.roles[0].compile.argv=@($flag)
  foreach($source in $f.canonical_source_snapshot.files){$candidate.manifest.canonical_source_snapshot.files+=@([ordered]@{path=$source.path;sha256=$source.sha256;size_bytes=(Get-Item -LiteralPath (Join-Path $RepoRoot $source.path)).Length})}
  $candidate.manifest.canonical_source_snapshot.files+=@([ordered]@{path='tools/read_r19_diagnostic_usb_failure_record.ps1';sha256=$f.diagnostic_usb_failure_diagnostics.decoder.sha256;size_bytes=(Get-Item -LiteralPath $script:R19DiagnosticUsbFailureDecoderPath).Length})
  Copy-Item -LiteralPath $script:R19DiagnosticUsbFailureDecoderPath -Destination (Join-Path $candidate.root 'evidence/tools/read_r19_diagnostic_usb_failure_record.ps1')
  Save-Candidate $candidate;return $candidate
}
function BindV8($Candidate){Assert-ArtifactBinding -Root $Candidate.root -ExpectedArtifactId mock-candidate -ExpectedRole ground -ExpectedAddress ([uint32]0x3fcab000)}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmEight)
$candidate=NewV8Candidate 'positive';$bound=BindV8 $candidate
Check ($bound.diagnostic_usb_failure_enabled-and$bound.diagnostic_usb_failure_address-ceq'0x3fcad800'-and$bound.symbols.Count-eq8-and$script:R19DiagnosticUsbDecoderVerifiedSha256-ceq$bound.diagnostic_usb_failure_diagnostics.decoder.sha256) 'sealed v8 exact eight-symbol decoder binding positive'
foreach($mutation in @('sealed-metadata','downgrade','missing-symbol','wrong-size','missing-decoder','decoder-source','capability-source','capability-privilege','missing-flag','undeclared-contract')){
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmEight);$candidate=NewV8Candidate ('reject-'+$mutation)
  switch($mutation){
    'sealed-metadata'{$candidate.seal.Remove('diagnostic_usb_failure_diagnostics')}
    'downgrade'{$candidate.handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v7'}
    'missing-symbol'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($nmEight-split"`n"|Where-Object{$_-notmatch'diagnostic_usb_failure_record'})-join"`n"))}
    'wrong-size'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmEight.Replace('00000100 B vc_lora_r19_diagnostic','000000fc B vc_lora_r19_diagnostic'))}
    'missing-decoder'{Remove-Item -LiteralPath (Join-Path $candidate.root 'evidence/tools/read_r19_diagnostic_usb_failure_record.ps1')}
    'decoder-source'{$candidate.manifest.canonical_source_snapshot.files=@($candidate.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/read_r19_diagnostic_usb_failure_record.ps1'})}
    'capability-source'{$candidate.manifest.canonical_source_snapshot.files=@($candidate.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/r19_usb_role_contract.ps1'})}
    'capability-privilege'{$candidate.manifest.usb_role_capabilities.roles[0].arm=$true}
    'missing-flag'{$candidate.manifest.roles[0].compile.argv=@((Get-R19CandidateCompileProperty $true ExplicitHostArm $true))}
    'undeclared-contract'{foreach($doc in @($candidate.manifest,$candidate.seal,$candidate.handoff)){$doc.Remove('diagnostic_usb_failure_diagnostics')}}
  }
  Save-Candidate $candidate;$rejected=$false;try{$null=BindV8 $candidate}catch{$rejected=$true};Check $rejected ('sealed candidate reject '+$mutation)
}
Write-Output "DIAGNOSTIC_USB_FAILURE_RECORD PASS $script:checks checks fixtures=$fixtureRoot"
