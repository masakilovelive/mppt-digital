[CmdletBinding()]
param([string]$RepoRoot,[string]$OutputRoot)
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Join-Path $PSScriptRoot '../..'}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-timed-outer-raw-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$OutputRoot=(Resolve-Path $OutputRoot).Path
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){
  $script:proofObservation=$null
  try{$script:rejectionReason='';&$Body;$item=[ordered]@{name=$Name;passed=$true};if($script:rejectionReason){$item['rejection_reason']=$script:rejectionReason}}
  catch{$item=[ordered]@{name=$Name;passed=$false;error=$_.Exception.Message}}
  if($null-ne$script:proofObservation){$item['observed_proof']=$script:proofObservation}
  $checks.Add($item)
}
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Import-Functions([string]$Path,[string[]]$Names){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  Require ($errors.Count-eq0) ('parse error: '+$Path)
  foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($Names.Count-eq0-or$f.Name-cin$Names){. ([scriptblock]::Create('function script:'+($f.Extent.Text.Substring(9))))}
  }
  return ,$ast
}
$outerAst=Import-Functions (Join-Path $repo 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') @()
$readerAst=Import-Functions (Join-Path $repo 'tools/read_r19_runtime_stage_jtag.ps1') @('Assert-Condition','Convert-Words','Decode-StableStageRecord','Decode-StableFifoRecord','Decode-StableDiagnosticRecords','Decode-ExtendedStableWords','Decode-ExtendedRestartState','Decode-ExtendedRestartRecord','Decode-ExtendedCommitRecord')
foreach($name in @('stageRecordBytes','fifoRecordBytes','stageNames','failureNames','fifoFlushOutcomeNames','fifoFlagNames','fifoFlushBlockerNames','fifoBusResetInterruptMask')){
  $nodes=@($readerAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq('$'+$name)},$true))
  Require ($nodes.Count-eq1) ('reader constant absent: '+$name)
  . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$null=Import-Functions (Join-Path $repo 'tests/arduino_compile/check_r19_usb_extended_records_reader_contract.ps1') @('Pack-Words','New-Fixture','Set-Word','New-LatchedFixture')
$null=Import-Functions (Join-Path $repo 'tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1') @('New-ValidStageV3Summary','New-ValidExtendedSummary','Get-ExtendedProof')
$firstAst=Import-Functions (Join-Path $repo 'tests/hil/check_r19_first_usb_failure_outer_contract.ps1') @('New-FirstWords','New-ExpectedFirst','New-V5Summary')
$abiNodes=@($firstAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$validExtendedAbi'},$true))
Require ($abiNodes.Count-eq1) 'legacy ABI fixture assignment absent'
. ([scriptblock]::Create($abiNodes[0].Extent.Text))
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
. (Join-Path $repo 'tools/read_r19_timed_path_record.ps1')
$candidateArtifactId='offline-outer-timed-path-v6'
$stageRuntimeSha256='';$stageRuntimeFirstPath='';$stageRuntimeSecondPath='';$stageFifoSha256='';$stageFifoFirstPath='';$stageFifoSecondPath=''
$OfflineContractTest=[switch]$false
$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
$utf8=[Text.UTF8Encoding]::new($false)
$extendedDirectory=Join-Path $OutputRoot 'fixture'
New-Item -ItemType Directory -Path $extendedDirectory -Force|Out-Null
$extendedManifestPath=Join-Path $extendedDirectory 'candidate_manifest.json'
$extendedSizes=[ordered]@{runtime_stage=68;endpoint_fifo=112;hwcdc_restart=128;ground_usb_commit=128}
$extendedSymbols=[ordered]@{runtime_stage='vc_lora_r19_runtime_stage_record';endpoint_fifo='vc_lora_r19_hwcdc_fifo_diagnostic_record';hwcdc_restart='vc_lora_r19_hwcdc_restart_diagnostic_record';ground_usb_commit='vc_lora_r19_ground_usb_commit_record'}
$extendedLeaves=@{runtime_stage='runtime-stage';endpoint_fifo='endpoint-fifo';hwcdc_restart='hwcdc-restart';ground_usb_commit='ground-usb-commit'}
function Set-U32([byte[]]$Bytes,[int]$Word,[uint32]$Value){[BitConverter]::GetBytes($Value).CopyTo($Bytes,4*$Word)}
function Copy-Json($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
function New-TimedWords {
  [uint32[]]$w=New-Object uint32[] 128
  $w[1]=16;$w[2]=0x52313954;$w[3]=1;$w[4]=1
  $w[5]=0x52313944;$w[6]=0x53544731;$w[7]=0x32303236;$w[8]=0x31303033
  $w[9]=170;$w[10]=187;$w[11]=204;$w[12]=221
  $w[13]=191;$w[14]=2;$w[15]=1;$w[16]=91;$w[18]=0x123;$w[19]=0x52190000
  $w[20]=7;$w[21]=21;$w[22]=21;$w[23]=1;$w[24]=106;$w[25]=1
  $w[26]=4750000;$w[28]=4800000;$w[30]=4900010;$w[32]=4900010
  $w[34]=4900010;$w[36]=4800000;$w[38]=4900000;$w[40]=4916000
  $w[44]=31;$w[46]=31;$w[48]=5;$w[50]=1;$w[52]=4700000
  [byte[]]$bytes=Pack-Words $w
  # Exact unsigned 21-byte MAVLink2 Heartbeat image exported by the C++ record
  # test. Fixture-only identity/times above bind it to the legacy raw fixtures.
  [byte[]]$frame=[Convert]::FromBase64String('/QkAACsBAQAAAAAAAAACAwAEA65W')
  [Array]::Copy($frame,0,$bytes,232,$frame.Length)
  return ,$bytes
}
function Save-Manifest($Manifest,$Summary){
  [IO.File]::WriteAllText($extendedManifestPath,($Manifest|ConvertTo-Json -Depth 30),$utf8)
  $script:extendedFixtureCandidate.candidate_manifest_sha256=Get-Sha256 $extendedManifestPath
  $Summary.binding.artifact.manifest_sha256=$script:extendedFixtureCandidate.candidate_manifest_sha256
}
function New-V6Summary {
  $s=New-V5Summary
  $s.schema='vc-lora-r19-runtime-stage-jtag-read-v6'
  $manifest=Get-Content -LiteralPath $extendedManifestPath -Raw|ConvertFrom-Json
  $contract=Get-R19TimedPathCandidateContract $repo $TimedPathMode
  $manifest|Add-Member NoteProperty timed_path_diagnostics $contract
  $symbol=[pscustomobject]@{name='vc_lora_r19_timed_path_record';address='0x3fcab600';size_bytes=512;aligned_32_bit=$true}
  $manifest.roles[0].runtime_diagnostic_symbols.symbols|Add-Member NoteProperty timed_path $symbol
  $s.binding.artifact.symbols|Add-Member NoteProperty timed_path (Copy-Json $symbol)
  $s.binding.artifact.extended_record_metadata.symbols|Add-Member NoteProperty timed_path (Copy-Json $symbol)
  $s.binding|Add-Member NoteProperty timed_path_address $symbol.address
  $s.binding|Add-Member NoteProperty timed_path_diagnostics (Copy-Json $contract)
  $s.binding.artifact|Add-Member NoteProperty timed_path_diagnostics (Copy-Json $contract)
  $decoder=Join-Path $repo $contract.decoder.path
  $sealedDecoder=Join-Path $extendedDirectory ('evidence/'+$contract.decoder.path)
  Copy-Item -LiteralPath $decoder -Destination $sealedDecoder -Force
  $map=[string]$s.binding.artifact.map_path
  [IO.File]::AppendAllText($map,[Environment]::NewLine+'0x3fcab600 vc_lora_r19_timed_path_record',$utf8)
  $mapSha=Get-Sha256 $map
  $manifest.roles[0].runtime_diagnostic_symbols.map_sha256=$mapSha
  $manifest.roles[0].reproducibility_artifacts.files[1].sha256=$mapSha
  $s.binding.artifact.map_sha256=$mapSha
  $s.binding.artifact.extended_record_metadata.map_sha256=$mapSha
  # The same private clock request is mirrored in the first-failure record.
  foreach($read in @($s.reads|Where-Object{$_.record-ceq'first_usb_failure'})){
    [byte[]]$first=[IO.File]::ReadAllBytes($read.path);Set-U32 $first 18 4700000
    [IO.File]::WriteAllBytes($read.path,$first);$read.sha256=Get-Sha256 $read.path
  }
  $s.decoded.first_usb_failure=New-ExpectedFirst $first
  $s.decoded.first_usb_failure.clock_sync.device_us='4700000'
  [byte[]]$timed=New-TimedWords
  foreach($sample in 1,2){
    $leaf=if($sample-eq1){'timed_path_first.bin'}else{'timed_path_second.bin'}
    $path=Join-Path $extendedDirectory $leaf;[IO.File]::WriteAllBytes($path,$timed)
    $s.reads+=@([pscustomobject]@{record='timed_path';sample=$sample;size_bytes=512;path=$path;sha256=Get-Sha256 $path})
  }
  $s.decoded|Add-Member NoteProperty timed_path (ConvertFrom-R19TimedPathRecord $timed $timed 'ground' $TimedPathMode)
  Save-Manifest $manifest $s
  return $s
}
function Mutate-TimedRaw($Summary,[int]$Word,[uint32]$Value,[switch]$OnlyFirst,[switch]$RefreshProjection){
  foreach($read in @($Summary.reads|Where-Object{$_.record-ceq'timed_path'-and(-not$OnlyFirst-or$_.sample-eq1)})){
    [byte[]]$bytes=[IO.File]::ReadAllBytes($read.path);Set-U32 $bytes $Word $Value
    [IO.File]::WriteAllBytes($read.path,$bytes);$read.sha256=Get-Sha256 $read.path
  }
  if($RefreshProjection){
    [byte[]]$first=[IO.File]::ReadAllBytes($Summary.reads[10].path)
    [byte[]]$second=[IO.File]::ReadAllBytes($Summary.reads[11].path)
    $Summary.decoded.timed_path=ConvertFrom-R19TimedPathRecord $first $second 'ground' $TimedPathMode
  }
}
Check 'v6-twelve-raw-baseline-through-real-outer-replay' {
  $s=New-V6Summary;$proof=Get-ExtendedProof $s
  Require ($proof.proven-and$proof.extended_raw_replay.raw_read_count-eq12-and
    $proof.extended_raw_replay.timed_path_record.usb_failed-and
    $proof.extended_raw_replay.timed_path_record.nonce-ceq'5915759585527857443') ('baseline rejected: '+$proof.validation_error)
  Require (-not$proof.extended_raw_replay.record_acquisition_proves_usb_success-and
    $proof.cleanup_proven-and$proof.native_processes_termination_proven-and-not$proof.target_may_be_halted) 'raw acquisition invented USB success or lost cleanup'
}
foreach($case in @('raw-sha','raw-unrehashed','unstable-pair','wrong-order','missing-timed','extra-timed',
    'short-raw','wrong-size','outside-path','wrong-leaf','odd-sequence','active-writer','reserved',
    'wrong-role','raw-mode','raw-boot','raw-build','raw-nonce','raw-clock-sample',
    'decoded-count','decoded-mode','decoded-sha','decoded-boot','metadata-size','metadata-address',
    'decoder-sha','decoder-path','decoder-file','mode-binding','capture-termination','cleanup-false',
    'cleanup-string','native-string','target-string','target-halted')){
  Check ('v6-reject-'+$case) {
    $s=New-V6Summary
    switch($case){
      'raw-sha'{$s.reads[10].sha256='0'*64}
      'raw-unrehashed'{[byte[]]$b=[IO.File]::ReadAllBytes($s.reads[10].path);$b[0]=1;[IO.File]::WriteAllBytes($s.reads[10].path,$b)}
      'unstable-pair'{Mutate-TimedRaw $s 50 2 -OnlyFirst}
      'wrong-order'{$swap=$s.reads[10];$s.reads[10]=$s.reads[11];$s.reads[11]=$swap}
      'missing-timed'{$s.reads=@($s.reads|Select-Object -First 11)}
      'extra-timed'{$s.reads+=@($s.reads[10])}
      'short-raw'{[byte[]]$b=[IO.File]::ReadAllBytes($s.reads[10].path);[IO.File]::WriteAllBytes($s.reads[10].path,$b[0..507]);$s.reads[10].sha256=Get-Sha256 $s.reads[10].path}
      'wrong-size'{$s.reads[10].size_bytes=508}
      'outside-path'{$p=Join-Path $OutputRoot 'timed_path_first.bin';Copy-Item -LiteralPath $s.reads[10].path -Destination $p -Force;$s.reads[10].path=$p}
      'wrong-leaf'{$p=Join-Path $extendedDirectory 'wrong.bin';Copy-Item -LiteralPath $s.reads[10].path -Destination $p -Force;$s.reads[10].path=$p}
      'odd-sequence'{Mutate-TimedRaw $s 1 17}
      'active-writer'{Mutate-TimedRaw $s 0 1}
      'reserved'{Mutate-TimedRaw $s 54 1}
      'wrong-role'{Mutate-TimedRaw $s 4 2}
      'raw-mode'{Mutate-TimedRaw $s 14 1}
      'raw-boot'{Mutate-TimedRaw $s 9 171 -RefreshProjection}
      'raw-build'{Mutate-TimedRaw $s 5 1 -RefreshProjection}
      'raw-nonce'{Mutate-TimedRaw $s 18 292 -RefreshProjection}
      'raw-clock-sample'{Mutate-TimedRaw $s 52 4700001 -RefreshProjection}
      'decoded-count'{$s.decoded.timed_path.accepted_bytes=20}
      'decoded-mode'{$s.decoded.timed_path.mode='SyncOnly'}
      'decoded-sha'{$s.decoded.timed_path.frame_sha256='0'*64}
      'decoded-boot'{$s.decoded.timed_path.boot_id[0]=171}
      'metadata-size'{$s.binding.artifact.extended_record_metadata.symbols.timed_path.size_bytes=508}
      'metadata-address'{$s.binding.timed_path_address='0x3fcab604'}
      'decoder-sha'{$s.binding.timed_path_diagnostics.decoder.sha256='0'*64}
      'decoder-path'{$s.binding.timed_path_diagnostics.decoder.path='tools/other.ps1'}
      'decoder-file'{[IO.File]::AppendAllText((Join-Path $extendedDirectory 'evidence/tools/read_r19_timed_path_record.ps1'),'# changed',$utf8)}
      'mode-binding'{$s.binding.timed_path_diagnostics.mode='SyncOnly'}
      'capture-termination'{$s.safety.capture_process_termination_proven=$false}
      'cleanup-false'{$s.safety.resume_shutdown_cleanup_proven=$false}
      'cleanup-string'{$s.safety.resume_shutdown_cleanup_proven='false'}
      'native-string'{$s.safety.native_processes_termination_proven='false'}
      'target-string'{$s.safety.target_may_be_halted=''}
      'target-halted'{$s.safety.target_may_be_halted=$true}
    }
    $proof=Get-ExtendedProof $s
    $script:proofObservation=[ordered]@{proven=[bool]$proof.proven
      validation_error=[string]$proof.validation_error;cleanup_proven=[bool]$proof.cleanup_proven
      native_processes_termination_proven=[bool]$proof.native_processes_termination_proven
      target_may_be_halted=[bool]$proof.target_may_be_halted}
    Require (-not$proof.proven) ('unsafe v6 accepted: '+$case)
    Require (-not[string]::IsNullOrWhiteSpace($proof.validation_error)) ('v6 rejected without reason: '+$case)
    Require ($proof.validation_error-cnotmatch'unsupported.version|invalid diagnostic ABI|Reader generation does not match') ('mutation stopped at unrelated version rejection: '+$case+' '+$proof.validation_error)
    if($case-cin@('raw-sha','unstable-pair','raw-boot','raw-nonce')){
      Require ($proof.cleanup_proven-and$proof.native_processes_termination_proven-and-not$proof.target_may_be_halted) 'invalid record erased independently proven cleanup'
    }
    if($case-ceq'cleanup-false'){Require (-not$proof.cleanup_proven) 'cleanup false became true'}
    if($case-ceq'cleanup-string'){Require (-not$proof.cleanup_proven) 'invalid string cleanup flag became true'}
    if($case-ceq'native-string'){Require (-not$proof.native_processes_termination_proven) 'invalid string native termination became true'}
    if($case-ceq'target-string'){Require $proof.target_may_be_halted 'invalid string halt flag became safe running'}
    $script:rejectionReason=$proof.validation_error
  }
}
$failed=@($checks|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-timed-path-outer-raw-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;checks=@($checks)}
$summary|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 16
if($failed.Count){exit 1}
