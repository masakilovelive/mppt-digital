[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-first-outer-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$OutputRoot=(Resolve-Path $OutputRoot).Path
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{$script:rejectionReason='';&$Body;$item=[ordered]@{name=$Name;passed=$true};if($script:rejectionReason){$item['rejection_reason']=$script:rejectionReason};$checks.Add($item)}catch{$checks.Add([ordered]@{name=$Name;passed=$false;error=$_.Exception.Message})}}
function Require([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Import-Functions([string]$Path,[string[]]$Names){
  $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
  Require ($e.Count-eq0) ('parse error: '+$Path)
  foreach($f in $a.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($Names.Count-eq0-or$f.Name-cin$Names){. ([scriptblock]::Create('function script:'+($f.Extent.Text.Substring(9))))}
  }
  return ,$a
}
$outer=Join-Path $repo 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1'
$legacy=Join-Path $repo 'tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1'
$reader=Join-Path $repo 'tools/read_r19_runtime_stage_jtag.ps1'
$outerAst=Import-Functions $outer @()
$readerAst=Import-Functions $reader @('Assert-Condition','Convert-Words','Decode-StableStageRecord','Decode-StableFifoRecord','Decode-StableDiagnosticRecords','Decode-ExtendedStableWords','Decode-ExtendedRestartState','Decode-ExtendedRestartRecord','Decode-ExtendedCommitRecord')
foreach($name in @('stageRecordBytes','fifoRecordBytes','stageNames','failureNames','fifoFlushOutcomeNames','fifoFlagNames','fifoFlushBlockerNames','fifoBusResetInterruptMask')){
  $nodes=@($readerAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq('$'+$name)},$true))
  Require ($nodes.Count-eq1) ('reader constant absent: '+$name);. ([scriptblock]::Create($nodes[0].Extent.Text))
}
$null=Import-Functions (Join-Path $repo 'tests/arduino_compile/check_r19_usb_extended_records_reader_contract.ps1') @('Pack-Words','New-Fixture','Set-Word','New-LatchedFixture')
$null=Import-Functions $legacy @('New-ValidStageV3Summary','New-ValidExtendedSummary','Get-ExtendedProof')
$candidateArtifactId='offline-outer-first-failure'
$stageRuntimeSha256='';$stageRuntimeFirstPath='';$stageRuntimeSecondPath='';$stageFifoSha256='';$stageFifoFirstPath='';$stageFifoSecondPath=''
$OfflineContractTest=[switch]$false
$utf8=[Text.UTF8Encoding]::new($false)
$extendedDirectory=Join-Path $OutputRoot 'fixture';New-Item -ItemType Directory -Path $extendedDirectory -Force|Out-Null
$extendedManifestPath=Join-Path $extendedDirectory 'candidate_manifest.json'
$extendedSizes=[ordered]@{runtime_stage=68;endpoint_fifo=112;hwcdc_restart=128;ground_usb_commit=128}
$extendedSymbols=[ordered]@{runtime_stage='vc_lora_r19_runtime_stage_record';endpoint_fifo='vc_lora_r19_hwcdc_fifo_diagnostic_record';hwcdc_restart='vc_lora_r19_hwcdc_restart_diagnostic_record';ground_usb_commit='vc_lora_r19_ground_usb_commit_record'}
$extendedLeaves=@{runtime_stage='runtime-stage';endpoint_fifo='endpoint-fifo';hwcdc_restart='hwcdc-restart';ground_usb_commit='ground-usb-commit'}
$validExtendedAbi=[ordered]@{endpoint_fifo_schema=2;endpoint_fifo_size_bytes=112;runtime_stage_size_bytes=68;reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4';usb_extended_diagnostics=[ordered]@{schema='vc-lora-r19-usb-extended-diagnostics-v1';enabled=$true;records=[ordered]@{hwcdc_restart=[ordered]@{symbol='vc_lora_r19_hwcdc_restart_diagnostic_record';schema_version=1;size_bytes=128};ground_usb_commit=[ordered]@{symbol='vc_lora_r19_ground_usb_commit_record';schema_version=1;size_bytes=128}}}}|ConvertTo-Json -Depth 12|ConvertFrom-Json
function New-FirstWords {
  [uint32[]]$w=[uint32[]]::new(96)
  $w[1]=6;$w[2]=0x52313955;$w[3]=1;$w[4]=1
  $w[5]=0x52313944;$w[6]=0x53544731;$w[7]=0x32303236;$w[8]=0x31303033
  $w[9]=170;$w[10]=187;$w[11]=204;$w[12]=221;$w[13]=7;$w[14]=1
  $w[16]=0x123;$w[17]=0x52190000;$w[18]=6000000
  $w[20]=1;$w[21]=3178;$w[22]=7;$w[23]=1;$w[24]=13;$w[25]=106;$w[26]=1;$w[27]=1
  $w[28]=4800000;$w[30]=4900000;$w[32]=4916000;$w[34]=21;$w[35]=21;$w[60]=4900010
  $w[36]=1;$w[37]=31;$w[38]=7;$w[39]=1;$w[40]=5;$w[41]=100;$w[46]=100;$w[50]=31
  return ,$w
}
function New-ExpectedFirst([byte[]]$Bytes){
  $hash=[Security.Cryptography.SHA256]::Create();try{$sha=([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','')}finally{$hash.Dispose()}
  $sdk=[ordered]@{schema=1;validity_flags=31;transaction_token=7;attempt_id=1;terminal_reason=5;timeout_ms=100;expected_loss_epoch=0;started_ms=0;finished_ms=0;lock_wait_ms=0;elapsed_ms=100;raw_return=0;state_flags=0;observed_loss_epoch=0;ring_pending_bytes=31;stash_pending_bytes=0;publish_generation=0;pickup_generation=0;raw_interrupt_status=0;interrupt_enable_mask=0;flush_blocker_mask=0;snapshot_started_ms=0;snapshot_finished_ms=0;snapshot_duration_us=0;snapshot_observed=$true;lock_acquired=$true;terminal_name='LoopTimeout'}
  [ordered]@{schema='vc-lora-r19-first-usb-failure-decoded-v1';result='PASS';mode='offline-only';hardware_interaction=$false;raw_size_bytes=384;raw_sha256=$sha;sequence=6;record_schema=1;role='ground';build_fingerprint=@(0x52313944,0x53544731,0x32303236,0x31303033);boot_instance=@(170,187,204,221);failure_latched=$true;clock_sync=[ordered]@{observed=$true;sync_count=1;nonce='5915759585527857443';device_us='6000000'};first_failure=[ordered]@{reason=1;source_line=3178;token=7;attempt_id=1;wrapper_flags=13;api_called=$true;raw_return=$false;budget_ms=106;expected_epoch=1;observed_epoch=1;started_us='4800000';finished_us='4900000';deadline_us='4916000';failure_observed_us='4900010';elapsed_us='100000';expected_frame_bytes=21;accepted_frame_bytes=21;sdk=$sdk};acceptance='NOT_EVALUATED'}|ConvertTo-Json -Depth 16|ConvertFrom-Json
}
function New-V5Summary {
  $s=New-ValidExtendedSummary
  $s.schema='vc-lora-r19-runtime-stage-jtag-read-v5'
  $m=Get-Content $extendedManifestPath -Raw|ConvertFrom-Json
  $m.reader_schema=$s.schema;$m.usb_extended_diagnostics.schema='vc-lora-r19-usb-extended-diagnostics-v2'
  $m.usb_extended_diagnostics.records|Add-Member NoteProperty first_usb_failure ([pscustomobject]@{symbol='vc_lora_r19_first_usb_failure_record';schema_version=1;size_bytes=384})
  $descriptor=[pscustomobject]@{path='tools/read_r19_first_usb_failure_record.ps1';sha256=(Get-Sha256 (Join-Path $repo 'tools/read_r19_first_usb_failure_record.ps1'))}
  $m|Add-Member NoteProperty first_usb_failure_decoder $descriptor
  $decoderCopy=Join-Path $extendedDirectory 'evidence/tools/read_r19_first_usb_failure_record.ps1';New-Item -ItemType Directory -Path (Split-Path $decoderCopy -Parent) -Force|Out-Null
  Copy-Item -LiteralPath (Join-Path $repo $descriptor.path) -Destination $decoderCopy
  $symbol=[pscustomobject]@{name='vc_lora_r19_first_usb_failure_record';address='0x3fcab400';size_bytes=384;aligned_32_bit=$true}
  $m.roles[0].runtime_diagnostic_symbols.symbols|Add-Member NoteProperty first_usb_failure $symbol
  $s.binding.artifact.symbols|Add-Member NoteProperty first_usb_failure $symbol
  $s.binding.artifact.extended_record_metadata.symbols|Add-Member NoteProperty first_usb_failure $symbol
  $map=[string]$s.binding.artifact.map_path;[IO.File]::AppendAllText($map,[Environment]::NewLine+'0x3fcab400 vc_lora_r19_first_usb_failure_record',$utf8)
  $mapSha=Get-Sha256 $map;$m.roles[0].runtime_diagnostic_symbols.map_sha256=$mapSha;$m.roles[0].reproducibility_artifacts.files[1].sha256=$mapSha
  $s.binding.artifact.map_sha256=$mapSha;$s.binding.artifact.extended_record_metadata.map_sha256=$mapSha
  [IO.File]::WriteAllText($extendedManifestPath,($m|ConvertTo-Json -Depth 20),$utf8)
  $script:extendedFixtureCandidate.candidate_manifest_sha256=Get-Sha256 $extendedManifestPath;$script:extendedFixtureCandidate.reader_schema=$s.schema
  $s.binding.artifact.manifest_sha256=$script:extendedFixtureCandidate.candidate_manifest_sha256
  $s.binding|Add-Member NoteProperty first_usb_failure_address $symbol.address
  $s.binding|Add-Member NoteProperty first_usb_failure_decoder ($descriptor|ConvertTo-Json|ConvertFrom-Json)
  $s.binding.artifact|Add-Member NoteProperty first_usb_failure_decoder $descriptor
  [byte[]]$bytes=Pack-Words (New-FirstWords)
  $reads=@();foreach($sample in 1,2){$reads+=@($s.reads|Where-Object{$_.sample-eq$sample});$suffix=if($sample-eq1){'first'}else{'second'};$path=Join-Path $extendedDirectory ('first-usb-failure-'+$suffix+'.bin');[IO.File]::WriteAllBytes($path,$bytes);$reads+=@([pscustomobject]@{record='first_usb_failure';sample=$sample;size_bytes=384;path=$path;sha256=Get-Sha256 $path})}
  $s.reads=$reads;$s.decoded|Add-Member NoteProperty first_usb_failure (New-ExpectedFirst $bytes)
  return $s
}
Check 'legacy-v4-eight-raw-remains-valid' {$s=New-ValidExtendedSummary;Require (Get-ExtendedProof $s).proven 'legacy v4 rejected'}
Check 'new-v5-ten-raw-first-failure-is-independently-proven' {
  $s=New-V5Summary;$p=Get-ExtendedProof $s
  Require ($p.proven-and$p.extended_raw_replay.raw_read_count-eq10-and$p.extended_raw_replay.first_usb_failure.failure_latched) ('v5 rejected: '+$p.validation_error)
  Require ($p.extended_raw_replay.first_usb_failure.first_failure.sdk.terminal_name-ceq'LoopTimeout') 'raw first failure reason absent'
  Require ($p.extended_raw_replay.first_usb_failure_pc_time_relation.classification-ceq'UNKNOWN'-and-not$p.extended_raw_replay.record_acquisition_proves_usb_success) 'acquisition or device timestamps were promoted to USB success/PC time ordering'
  $cause=Get-FirstUsbFailureCauseObservation $p
  Require ($cause.record_acquisition-ceq'PROVEN'-and$cause.first_failure_observation-ceq'LATCHED'-and$cause.wait_reason-ceq'LoopTimeout'-and$cause.pc_time_relation-ceq'UNKNOWN'-and-not$cause.acquisition_proves_usb_success-and-not$cause.acquisition_proves_pc_consumption) 'cause summary overstates acquisition or clock order'
}
Check 'v5-abi-accepted-v4-mixed-extension-rejected' {
  $s=New-V5Summary;$m=Get-Content $extendedManifestPath -Raw|ConvertFrom-Json;Assert-CandidateDiagnosticAbiContract $m 'v5'
  $m.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4';$rejected=$false;try{Assert-CandidateDiagnosticAbiContract $m 'mixed'}catch{$rejected=$true};Require $rejected 'mixed extension accepted'
}
foreach($case in @('missing-fifth','wrong-order','short-size','outside-path','sha-tamper','unstable-pair','odd-lock','reserved','wrong-role','zero-boot','wrong-sdk-token','wrapper-bool','decoded-boot','decoded-sdk','downgrade','missing-symbol','decoder-hash','top-decoder-hash','missing-top-decoder','sdk-reserved-mask','missing-decoded','string-latched','string-api-called','string-sync-observed','string-hardware-false','decoded-nonce','numeric-nonce','string-sdk-token','decoded-build','decoded-role','extra-raw','duplicate-raw','raw-build','raw-nonce','unknown-wrapper-bit')){
  Check ('v5-reject-'+$case) {
    $s=New-V5Summary
    switch($case){
      'missing-fifth'{$s.reads=@($s.reads|Where-Object{$_.record-cne'first_usb_failure'})}
      'wrong-order'{$tmp=$s.reads[4];$s.reads[4]=$s.reads[3];$s.reads[3]=$tmp}
      'short-size'{$s.reads[4].size_bytes=380}
      'outside-path'{$path=Join-Path $OutputRoot 'first-usb-failure-first.bin';Copy-Item -LiteralPath $s.reads[4].path -Destination $path -Force;$s.reads[4].path=$path}
      'sha-tamper'{$s.reads[4].sha256='0'*64}
      'wrapper-bool'{$s.decoded.first_usb_failure.first_failure.raw_return='false'}
      'decoded-boot'{$s.decoded.first_usb_failure.boot_instance[0]=171}
      'decoded-sdk'{$s.decoded.first_usb_failure.first_failure.sdk.lock_wait_ms=9}
      'downgrade'{$s.schema='vc-lora-r19-runtime-stage-jtag-read-v4'}
      'missing-symbol'{$s.binding.artifact.symbols.PSObject.Properties.Remove('first_usb_failure')}
      'decoder-hash'{$s.binding.artifact.first_usb_failure_decoder.sha256='0'*64}
      'top-decoder-hash'{$s.binding.first_usb_failure_decoder.sha256='0'*64}
      'missing-top-decoder'{$s.binding.PSObject.Properties.Remove('first_usb_failure_decoder')}
      'missing-decoded'{$s.decoded.PSObject.Properties.Remove('first_usb_failure')}
      'string-latched'{$s.decoded.first_usb_failure.failure_latched='true'}
      'string-api-called'{$s.decoded.first_usb_failure.first_failure.api_called='true'}
      'string-sync-observed'{$s.decoded.first_usb_failure.clock_sync.observed='true'}
      'string-hardware-false'{$s.decoded.first_usb_failure.hardware_interaction='false'}
      'decoded-nonce'{$s.decoded.first_usb_failure.clock_sync.nonce='5915759585527857444'}
      'numeric-nonce'{$s.decoded.first_usb_failure.clock_sync.nonce=[long]5915759585527857443}
      'string-sdk-token'{$s.decoded.first_usb_failure.first_failure.sdk.transaction_token='7'}
      'decoded-build'{$s.decoded.first_usb_failure.build_fingerprint[0]=1}
      'decoded-role'{$s.decoded.first_usb_failure.role='vehicle'}
      'extra-raw'{$s.reads+=@($s.reads[4])}
      'duplicate-raw'{$s.reads[9]=$s.reads[4]}
      default {
        $indices=if($case-ceq'unstable-pair'){@(4)}else{@(4,9)}
        foreach($index in $indices){$read=$s.reads[$index];[byte[]]$bytes=[IO.File]::ReadAllBytes($read.path)
          $word=0;$value=1;switch($case){'unstable-pair'{$word=23;$value=2}'odd-lock'{$word=1;$value=7}'reserved'{$word=62}'wrong-role'{$word=4;$value=2}'zero-boot'{foreach($i in 9..12){[BitConverter]::GetBytes([uint32]0).CopyTo($bytes,4*$i)};$word=9;$value=0}'wrong-sdk-token'{$word=38;$value=8}'sdk-reserved-mask'{$word=37;$value=0x100}'raw-build'{$word=5}'raw-nonce'{$word=17;$value=0x52180000}'unknown-wrapper-bit'{$word=24;$value=29}}
          [BitConverter]::GetBytes([uint32]$value).CopyTo($bytes,4*$word);[IO.File]::WriteAllBytes($read.path,$bytes);$read.sha256=Get-Sha256 $read.path
        }
      }
    }
    $p=Get-ExtendedProof $s
    Require (-not$p.proven-and-not[string]::IsNullOrWhiteSpace($p.validation_error)) ('unsafe v5 accepted or rejected without cause: '+$case)
    if($case-cne'downgrade'){Require ($p.validation_error-cnotmatch'Reader generation|invalid diagnostic ABI|schema downgrade') ('mutation reached unrelated unsupported-version rejection: '+$case+' '+$p.validation_error)}
    $script:rejectionReason=$p.validation_error
  }
}
foreach($index in 0..9){Check ('all-ten-raw-samples-rehashed-mutation-'+$index) {
  $s=New-V5Summary;$read=$s.reads[$index];[byte[]]$bytes=[IO.File]::ReadAllBytes($read.path);$bytes[0]=1
  [IO.File]::WriteAllBytes($read.path,$bytes);$read.sha256=Get-Sha256 $read.path
  $p=Get-ExtendedProof $s;Require (-not$p.proven-and$p.validation_error-match'raw samples differ|raw writer is active') ('raw mutation not rejected at raw boundary: '+$index)
  $script:rejectionReason=$p.validation_error
}}
Check 'vehicle-unlatched-and-uncalled-api-unknown-are-distinct' {
  [uint32[]]$w=New-FirstWords;$w[4]=2;$w[13]=1;$w[14]=0;foreach($i in 16..61){$w[$i]=0}
  $r=Get-RawFirstUsbFailureRecord $w 'vehicle' ('0'*64)
  Require (-not$r.failure_latched-and$null-eq$r.first_failure.raw_return-and$r.role-ceq'vehicle') 'unlatched Vehicle falsely classified failure or raw false'
  $w=New-FirstWords;$w[24]=4;foreach($i in 37..59){$w[$i]=0}
  $r=Get-RawFirstUsbFailureRecord $w 'ground' ('0'*64)
  Require ($r.failure_latched-and-not$r.first_failure.api_called-and$null-eq$r.first_failure.raw_return) 'uncalled API raw return must be unknown, not false'
}
Check 'independent-u64-decoding-retains-full-width-strings' {
  [uint32[]]$w=New-FirstWords
  $w[18]=66;$w[19]=[Convert]::ToUInt32('ABCDEF01',16)
  $w[28]=1;$w[29]=0x12345678;$w[30]=106001;$w[31]=0x12345678
  $w[32]=106001;$w[33]=0x12345678;$w[60]=106011;$w[61]=0x12345678
  $r=Get-RawFirstUsbFailureRecord $w 'ground' ('0'*64)
  Require ($r.clock_sync.device_us-is[string]-and$r.clock_sync.device_us-ceq'12379813738285367362'-and$r.first_failure.started_us-ceq'1311768464867721217'-and$r.first_failure.elapsed_us-ceq'106000') 'full-width independent first-failure replay lost integer precision'
}
$failed=@($checks|Where-Object{-not$_.passed})
$summary=[ordered]@{schema='vc-lora-r19-first-usb-failure-outer-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;checks=@($checks)}
$summary|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 14
if($failed.Count){exit 1}
