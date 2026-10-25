[CmdletBinding()]
param([string]$OutputRoot,[string]$CasePattern='*')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$reader = Join-Path $repo 'tools/read_r19_runtime_stage_jtag.ps1'
$script:R19FirstFailureDecoderPath=Join-Path $repo 'tools/read_r19_first_usb_failure_record.ps1'
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('r19-live-reader-contract-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRoot = (Resolve-Path $OutputRoot).Path
$checks = [Collections.Generic.List[object]]::new()
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($reader,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'reader syntax error' }
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
  . ([scriptblock]::Create($f.Extent.Text))
}
$stageRecordBytes=68; $fifoRecordBytes=112
function Check([string]$Name,[scriptblock]$Body) {
  if($Name-notlike$CasePattern){return}
  try { & $Body; $checks.Add([ordered]@{name=$Name;passed=$true}) }
  catch { $checks.Add([ordered]@{name=$Name;passed=$false;error=$_.Exception.Message}) }
}
function Require([bool]$Condition,[string]$Detail) { if(-not $Condition){throw $Detail} }
function Reject([scriptblock]$Body) { $rejected=$false; try { & $Body | Out-Null } catch {$rejected=$true}; Require $rejected 'mutation was admitted' }
function Json-Write($Value,[string]$Path) { $Value|ConvertTo-Json -Depth 18|Set-Content -LiteralPath $Path -Encoding UTF8 }
function New-Candidate([string]$Name,[bool]$Extended=$true) {
  $dir=Join-Path $OutputRoot $Name; New-Item -ItemType Directory -Path $dir -Force|Out-Null
  foreach($file in @('application.elf','application.map','application.bin')) {
    [IO.File]::WriteAllBytes((Join-Path $dir $file),[Text.Encoding]::ASCII.GetBytes($file))
  }
  $elf=Get-Sha256 (Join-Path $dir 'application.elf'); $map=Get-Sha256 (Join-Path $dir 'application.map'); $app=Get-Sha256 (Join-Path $dir 'application.bin')
  $symbols=[ordered]@{}
  foreach($s in @(@('runtime_stage','vc_lora_r19_runtime_stage_record','0x3fcab000',68),@('endpoint_fifo','vc_lora_r19_hwcdc_fifo_diagnostic_record','0x3fcab100',112),@('hwcdc_restart','vc_lora_r19_hwcdc_restart_diagnostic_record','0x3fcab200',128),@('ground_usb_commit','vc_lora_r19_ground_usb_commit_record','0x3fcab300',128))) {
    $symbols[$s[0]]=[ordered]@{name=$s[1];address=$s[2];size_bytes=$s[3];aligned_32_bit=$true}
  }
  $role=[ordered]@{role='ground';application=[ordered]@{sha256=$app;size_bytes=15};reproducibility_artifacts=[ordered]@{files=@([ordered]@{path='image/application.elf';sha256=$elf},[ordered]@{path='image/application.map';sha256=$map})}}
  New-Item -ItemType Directory -Path (Join-Path $dir 'image')|Out-Null
  Copy-Item -LiteralPath (Join-Path $dir 'application.elf') -Destination (Join-Path $dir 'image/application.elf')
  Copy-Item -LiteralPath (Join-Path $dir 'application.map') -Destination (Join-Path $dir 'image/application.map')
  $manifest=[ordered]@{schema='vc-lora-r19-candidate-artifact-manifest-v1';result='PASS';artifact_id='mock-candidate';runtime_fail_diagnostics_enabled=$true;roles=@($role)}
  $seal=[ordered]@{schema='vc-lora-r19-candidate-final-seal-v1';result='PASS';artifact_id='mock-candidate';runtime_fail_diagnostics_enabled=$true;ground_application_sha256=$app}
  $handoff=[ordered]@{schema='vc-lora-r19-candidate-artifact-handoff-v1';result='PASS';runtime_fail_diagnostics_enabled=$true;artifact_id='mock-candidate';roles=@([ordered]@{role='ground'})}
  if($Extended) {
    $extension=[ordered]@{schema='vc-lora-r19-usb-extended-diagnostics-v1';enabled=$true;records=[ordered]@{hwcdc_restart=[ordered]@{symbol='vc_lora_r19_hwcdc_restart_diagnostic_record';schema_version=1;size_bytes=128};ground_usb_commit=[ordered]@{symbol='vc_lora_r19_ground_usb_commit_record';schema_version=1;size_bytes=128}}}
    $metadata=[ordered]@{schema='vc-lora-r19-runtime-diagnostic-symbols-v1';elf_sha256=$elf;map_sha256=$map;application_sha256=$app;symbols=$symbols}
    $manifest.usb_extended_diagnostics=$extension; $seal.usb_extended_diagnostics=$extension; $handoff.usb_extended_diagnostics=$extension
    foreach($doc in @($manifest,$seal,$handoff)) {$doc.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4';$doc.runtime_stage_size_bytes=68;$doc.endpoint_fifo_schema=2;$doc.endpoint_fifo_size_bytes=112}
    $role.runtime_diagnostic_symbols=$metadata
    $seal.roles=@([ordered]@{role='ground';runtime_diagnostic_symbols=$metadata})
    $handoff.roles[0].runtime_diagnostic_symbols=$metadata
  }
  $candidate=[pscustomobject]@{root=$dir;manifest=$manifest;seal=$seal;handoff=$handoff;extended=$Extended}
  Save-Candidate $candidate
  $candidate
}
function Save-Candidate($C) {
  Json-Write $C.manifest (Join-Path $C.root 'candidate_manifest.json')
  $C.seal.candidate_manifest_sha256=Get-Sha256 (Join-Path $C.root 'candidate_manifest.json'); Json-Write $C.seal (Join-Path $C.root 'final_seal.json')
  $C.handoff.candidate_manifest=[ordered]@{path=(Join-Path $C.root 'candidate_manifest.json');sha256=$C.seal.candidate_manifest_sha256}
  $C.handoff.final_seal=[ordered]@{path=(Join-Path $C.root 'final_seal.json');sha256=Get-Sha256 (Join-Path $C.root 'final_seal.json')}
  Json-Write $C.handoff (Join-Path $C.root 'handoff.json')
  [IO.File]::WriteAllText((Join-Path $C.root 'handoff.sha256'),((Get-Sha256 (Join-Path $C.root 'handoff.json'))+' *handoff.json'+"`n"))
}
$mockNm=Join-Path $OutputRoot 'mock-nm.ps1'
@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record')|Set-Content -LiteralPath (Join-Path $OutputRoot 'nm.txt') -Encoding ASCII
@('param($SizeFlag,$DefinedFlag,$ElfPath)','Get-Content -LiteralPath (Join-Path $PSScriptRoot ''nm.txt'')','$global:LASTEXITCODE=0')|Set-Content -LiteralPath $mockNm -Encoding ASCII
$NmExecutable=$mockNm; $NmSha256=Get-Sha256 $mockNm
function Bind($C) { Assert-ArtifactBinding -Root $C.root -ExpectedArtifactId 'mock-candidate' -ExpectedRole 'ground' -ExpectedAddress ([uint32]0x3fcab000) }
Check 'v4-candidate-requires-all-four-symbols-and-manifest-metadata' {
  $c=New-Candidate 'binding-good'; $b=Bind $c
  Require ($b.extended_records_enabled-eq$true -and $b.hwcdc_restart_address-eq'0x3fcab200' -and $b.ground_usb_commit_address-eq'0x3fcab300' -and @($b.symbols.Keys).Count-eq4) 'extended binding was not returned'
}
foreach($mutation in @('missing-extension','disabled-extension','seal-extension-differs','handoff-extension-missing','missing-role-metadata','seal-role-differs','handoff-role-differs','wrong-elf-sha','wrong-map-sha','wrong-app-sha','metadata-symbol-address-differs','metadata-symbol-size-differs','unknown-record','missing-top-ABI','wrong-top-ABI','string-record-size','string-record-version','string-symbol-size')) {
  Check ('reject-'+$mutation) {
    $c=New-Candidate ('binding-'+$mutation)
    switch($mutation) {
      'missing-extension' {$c.manifest.Remove('usb_extended_diagnostics')}
      'disabled-extension' {$c.manifest.usb_extended_diagnostics.enabled=$false}
      'seal-extension-differs' {$c.seal.usb_extended_diagnostics=ConvertFrom-Json ($c.seal.usb_extended_diagnostics|ConvertTo-Json -Depth 12);$c.seal.usb_extended_diagnostics.records.hwcdc_restart.size_bytes=124}
      'handoff-extension-missing' {$c.handoff.Remove('usb_extended_diagnostics')}
      'missing-role-metadata' {$c.manifest.roles[0].Remove('runtime_diagnostic_symbols')}
      'seal-role-differs' {$c.seal.roles[0].runtime_diagnostic_symbols=ConvertFrom-Json ($c.seal.roles[0].runtime_diagnostic_symbols|ConvertTo-Json -Depth 12);$c.seal.roles[0].runtime_diagnostic_symbols.symbols.hwcdc_restart.address='0x3fcab204'}
      'handoff-role-differs' {$c.handoff.roles[0].runtime_diagnostic_symbols=ConvertFrom-Json ($c.handoff.roles[0].runtime_diagnostic_symbols|ConvertTo-Json -Depth 12);$c.handoff.roles[0].runtime_diagnostic_symbols.application_sha256='0'*64}
      'wrong-elf-sha' {$c.manifest.roles[0].runtime_diagnostic_symbols.elf_sha256='0'*64}
      'wrong-map-sha' {$c.manifest.roles[0].runtime_diagnostic_symbols.map_sha256='0'*64}
      'wrong-app-sha' {$c.manifest.roles[0].runtime_diagnostic_symbols.application_sha256='0'*64}
      'metadata-symbol-address-differs' {$c.manifest.roles[0].runtime_diagnostic_symbols.symbols.hwcdc_restart.address='0x3fcab204'}
      'metadata-symbol-size-differs' {$c.manifest.roles[0].runtime_diagnostic_symbols.symbols.hwcdc_restart.size_bytes=124}
      'unknown-record' {$c.manifest.usb_extended_diagnostics.records['unexpected']=[ordered]@{size_bytes=128}}
      'missing-top-ABI' {$c.manifest.Remove('endpoint_fifo_schema')}
      'wrong-top-ABI' {$c.seal.runtime_stage_size_bytes=64}
      'string-record-size' {$c.manifest.usb_extended_diagnostics.records.hwcdc_restart.size_bytes='128'}
      'string-record-version' {$c.manifest.usb_extended_diagnostics.records.hwcdc_restart.schema_version='1'}
      'string-symbol-size' {$c.manifest.roles[0].runtime_diagnostic_symbols.symbols.hwcdc_restart.size_bytes='128'}
    }
    Save-Candidate $c; Reject {Bind $c}
  }
}
$goodNm=[IO.File]::ReadAllText((Join-Path $OutputRoot 'nm.txt'))
foreach($mutation in @('missing-restart','missing-commit','duplicate-restart','wrong-restart-size','unaligned-restart','overlap-with-stage','address-wrap')) {
  Check ('reject-nm-'+$mutation) {
    $c=New-Candidate ('nm-'+$mutation); $n=$goodNm
    switch($mutation) {
      'missing-restart' {$n=$n-replace'(?m)^.*hwcdc_restart_diagnostic_record\s*',''}
      'missing-commit' {$n=$n-replace'(?m)^.*ground_usb_commit_record\s*',''}
      'duplicate-restart' {$n+="`n3fcab400 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record`n"}
      'wrong-restart-size' {$n=$n-replace'3fcab200 00000080','3fcab200 0000007c'}
      'unaligned-restart' {$n=$n-replace'3fcab200','3fcab201'}
      'overlap-with-stage' {$n=$n-replace'3fcab200','3fcab020'}
      'address-wrap' {$n=$n-replace'3fcab200','ffffffc0'}
    }
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$n); try {Reject {Bind $c}} finally {[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
  }
}
Check 'legacy-without-extension-preserves-two-record-binding' {
  $c=New-Candidate 'legacy' $false
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($goodNm-split"`r?`n"|Select-Object -First 2)-join"`n"))
  try {$b=Bind $c;Require (-not $b.extended_records_enabled -and @($b.symbols.Keys).Count-eq2) 'legacy binding changed'} finally {[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
}
Check 'extended-symbols-without-extension-fail-closed' {$c=New-Candidate 'legacy-stray-symbol' $false;Reject {Bind $c}}
Check 'v4-reader-schema-without-extension-fails-closed' {
  $c=New-Candidate 'legacy-contradictory-schema' $false;$c.manifest.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4';Save-Candidate $c
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($goodNm-split"`r?`n"|Select-Object -First 2)-join"`n"))
  try {Reject {Bind $c}} finally {[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
}
foreach($mutation in @('unknown-legacy-reader-schema','wrong-case-extension-schema','wrong-case-metadata-schema','wrong-case-property','missing-handoff-hash','incorrect-handoff-hash','wrong-manifest-reference','wrong-seal-reference','missing-manifest-reference','missing-seal-reference')) {
  Check ('strict-reject-'+$mutation) {
    $c=New-Candidate ('strict-'+$mutation)
    switch($mutation) {
      'unknown-legacy-reader-schema' {$c=New-Candidate ('strict-'+$mutation+'-legacy') $false;$c.manifest.reader_schema='unknown';Save-Candidate $c}
      'wrong-case-extension-schema' {$c.manifest.usb_extended_diagnostics.schema='VC-LORA-R19-USB-EXTENDED-DIAGNOSTICS-V1';Save-Candidate $c}
      'wrong-case-metadata-schema' {$c.manifest.roles[0].runtime_diagnostic_symbols.schema='VC-LORA-R19-RUNTIME-DIAGNOSTIC-SYMBOLS-V1';Save-Candidate $c}
      'wrong-case-property' {$e=$c.manifest.usb_extended_diagnostics;$c.manifest.usb_extended_diagnostics=[ordered]@{Schema=$e.schema;enabled=$e.enabled;records=$e.records};Save-Candidate $c}
      'missing-handoff-hash' {Remove-Item -LiteralPath (Join-Path $c.root 'handoff.sha256')}
      'incorrect-handoff-hash' {[IO.File]::WriteAllText((Join-Path $c.root 'handoff.sha256'),(('0'*64)+' *handoff.json'+"`n"))}
      'wrong-manifest-reference' {$c.handoff.candidate_manifest.sha256='0'*64;Json-Write $c.handoff (Join-Path $c.root 'handoff.json');[IO.File]::WriteAllText((Join-Path $c.root 'handoff.sha256'),((Get-Sha256 (Join-Path $c.root 'handoff.json'))+' *handoff.json'+"`n"))}
      'wrong-seal-reference' {$c.handoff.final_seal.sha256='0'*64;Json-Write $c.handoff (Join-Path $c.root 'handoff.json');[IO.File]::WriteAllText((Join-Path $c.root 'handoff.sha256'),((Get-Sha256 (Join-Path $c.root 'handoff.json'))+' *handoff.json'+"`n"))}
      'missing-manifest-reference' {$c.handoff.Remove('candidate_manifest');Json-Write $c.handoff (Join-Path $c.root 'handoff.json');[IO.File]::WriteAllText((Join-Path $c.root 'handoff.sha256'),((Get-Sha256 (Join-Path $c.root 'handoff.json'))+' *handoff.json'+"`n"))}
      'missing-seal-reference' {$c.handoff.Remove('final_seal');Json-Write $c.handoff (Join-Path $c.root 'handoff.json');[IO.File]::WriteAllText((Join-Path $c.root 'handoff.sha256'),((Get-Sha256 (Join-Path $c.root 'handoff.json'))+' *handoff.json'+"`n"))}
    }
    if($mutation-eq'unknown-legacy-reader-schema') {[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($goodNm-split"`r?`n"|Select-Object -First 2)-join"`n"))}
    try {Reject {Bind $c}} finally {[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
  }
}
Check 'one-SMP-halt-contains-eight-dumps-before-resume' {
  $function=($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Read-LiveStageRecord'},$true))[0].Extent.Text
  Require ($function-match'hwcdc_restart_first'-and$function-match'ground_usb_commit_second') 'live capture does not retain both extension samples'
  Require ($function-match'(?s)halt.*restartFirstPath.*commitFirstPath.*stageSecondPath.*restartSecondPath.*commitSecondPath.*catch \{ resume') 'four paired records do not share a halt'
}
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tests/arduino_compile/check_r19_usb_extended_records_reader_contract.ps1'),[ref]$tokens,[ref]$errors)
foreach($f in $fixtureAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-in@('Pack-Words','New-Fixture','Set-Word','New-LatchedFixture')},$true)) { . ([scriptblock]::Create($f.Extent.Text)) }
Check 'mocked-live-function-preserves-eight-raw-reads-in-single-halt' {
  & {
    $c=New-Candidate 'mocked-live';$b=Bind $c
    $fixture=New-LatchedFixture
    $ScriptsRoot=$OutputRoot;$OpenOcdExecutable=$reader;$OpenOcdSha256=Get-Sha256 $reader
    $InterfaceConfig=$reader;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$reader;$TargetConfigSha256=$OpenOcdSha256
    $ProbeSerial='1c:db:d4:5a:83:80';$ProbeUsbLocation='1-4.4'
    function Invoke-NativeProcessCapture {
      param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
      $command=$Arguments-join"`n"
      Require (@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1) 'must halt only once'
      Require (@($Arguments|Where-Object{$_-match'^dump_image '}).Count-eq8) 'expected eight dumps'
      Require ($command.IndexOf('VC_LORA_JTAG_IDENTITY_MATCHED')-lt$command.IndexOf("`nhalt`n")) 'identity must precede halt'
      $dumpMatches=[regex]::Matches($command,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
      Require ($dumpMatches.Count-eq8) 'dump syntax changed'
      $ordinal=0
      foreach($m in $dumpMatches) {
        $record=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')[$ordinal%4]
        $sample=if($ordinal-lt4){'first'}else{'second'}
        $bytes=[Convert]::FromBase64String($fixture[$record+'_'+$sample+'_read_base64'])
        Require ([int]$m.Groups[3].Value-eq$bytes.Length) 'record size changed'
        [IO.File]::WriteAllBytes($m.Groups[1].Value,$bytes);++$ordinal
      }
      @('VC_LORA_JTAG_OPEN_SERIAL=1c:db:d4:5a:83:80','VC_LORA_JTAG_OPEN_LOCATION=1-4.4','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')|Set-Content -LiteralPath $LogPath
      [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
    }
    function Invoke-OpenOcdCleanup { [pscustomobject]@{required=$true;attempted=$true;exit_code=0;process_termination_proven=$true;resume_shutdown_proven=$true} }
    $raw=Read-LiveStageRecord -Artifact $b -OutputDirectory $OutputRoot -Attempt 1
    Require ($raw.smp_capture_proven-and$raw.cleanup.resume_shutdown_proven) 'SMP cleanup proof missing'
    Require ($raw.stage_first.Length-eq68-and$raw.fifo_first.Length-eq112-and$raw.hwcdc_restart_first.Length-eq128-and$raw.hwcdc_restart_second.Length-eq128-and$raw.ground_usb_commit_first.Length-eq128-and$raw.ground_usb_commit_second.Length-eq128) 'raw records missing'
    $restart=Decode-ExtendedRestartRecord $raw.hwcdc_restart_first $raw.hwcdc_restart_second
    $commit=Decode-ExtendedCommitRecord $raw.ground_usb_commit_first $raw.ground_usb_commit_second 'ground'
    Require ($restart.latest.written_bytes-eq31-and$commit.source_line-eq3178) 'decoded latch was lost'
  }
}
$shellPath=if($PSVersionTable.PSEdition-eq'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
foreach($mutation in @('valid-v4','active-restart','odd-commit','unstable-restart','missing-commit-second','overlap-four-records')) {
  Check ('offline-v4-summary-'+$mutation) {
    $fixture=New-LatchedFixture
    switch($mutation){
      'active-restart'{Set-Word $fixture 'hwcdc_restart' 0 1}
      'odd-commit'{Set-Word $fixture 'ground_usb_commit' 1 3}
      'unstable-restart'{Set-Word $fixture 'hwcdc_restart' 1 4 -FirstOnly}
      'missing-commit-second'{$fixture.Remove('ground_usb_commit_second_read_base64')}
      'overlap-four-records'{$fixture.ground_usb_commit_address=$fixture.runtime_stage_address}
    }
    $case=Join-Path $OutputRoot ('v4-'+$mutation);New-Item -ItemType Directory -Path $case -Force|Out-Null
    $fixturePath=Join-Path $case 'fixture.json';Json-Write $fixture $fixturePath
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$reader+'"'),'-FixturePath',('"'+$fixturePath+'"'),'-OutputRoot',('"'+(Join-Path $case 'read')+'"'))
    $p=Start-Process -FilePath $shellPath -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $case 'stdout.txt') -RedirectStandardError (Join-Path $case 'stderr.txt')
    $summary=Get-Content -LiteralPath (Join-Path $case 'read/summary.json') -Raw|ConvertFrom-Json
    if($mutation-eq'valid-v4') {
      Require ($p.ExitCode-eq0-and$summary.schema-eq'vc-lora-r19-runtime-stage-jtag-read-v4'-and$summary.hardware_interaction-eq$false-and@($summary.reads).Count-eq8-and$summary.decoded.ground_usb_commit.source_line-eq3178) 'v4 summary or latch missing'
      $ordinal=0;foreach($read in $summary.reads){Require ($read.record-eq@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit')[$ordinal%4]) 'raw ordering differs';Require ((Get-Sha256 $read.path)-eq$read.sha256) 'raw hash mismatch';++$ordinal}
    } else {Require ($p.ExitCode-ne0-and$summary.result-eq'FAIL'-and-not$summary.hardware_interaction) 'invalid snapshot was admitted'}
  }
}
function New-FirstFailureCandidate([string]$Name) {
  $c=New-Candidate $Name
  New-Item -ItemType Directory -Path (Join-Path $c.root 'evidence/tools') -Force|Out-Null
  Copy-Item -LiteralPath $script:R19FirstFailureDecoderPath -Destination (Join-Path $c.root 'evidence/tools/read_r19_first_usb_failure_record.ps1')
  $c.manifest.canonical_source_snapshot=[ordered]@{files=@([ordered]@{path='tools/read_r19_first_usb_failure_record.ps1';size_bytes=(Get-Item -LiteralPath $script:R19FirstFailureDecoderPath).Length;sha256=Get-Sha256 $script:R19FirstFailureDecoderPath})}
  foreach($doc in @($c.manifest,$c.seal,$c.handoff)) {
    $doc.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v5'
    $doc.usb_extended_diagnostics.schema='vc-lora-r19-usb-extended-diagnostics-v2'
    $doc.usb_extended_diagnostics.records['first_usb_failure']=[ordered]@{symbol='vc_lora_r19_first_usb_failure_record';schema_version=1;size_bytes=384}
    $doc.first_usb_failure_decoder=[ordered]@{path='tools/read_r19_first_usb_failure_record.ps1';sha256=Get-Sha256 (Join-Path $repo 'tools/read_r19_first_usb_failure_record.ps1')}
    foreach($role in $doc.roles) {
      $role.runtime_diagnostic_symbols.symbols['first_usb_failure']=[ordered]@{name='vc_lora_r19_first_usb_failure_record';address='0x3fcab400';size_bytes=384;aligned_32_bit=$true}
    }
  }
  Save-Candidate $c
  $c
}
function New-FirstFailureFixture {
  $f=New-LatchedFixture;$f.schema='vc-lora-r19-usb-extended-jtag-fixture-v2';$f['first_usb_failure_address']='0x3fcab400'
  [uint32[]]$w=[uint32[]]::new(96)
  $w[1]=6;$w[2]=0x52313955;$w[3]=1;$w[4]=1;$w[5]=0x52313944;$w[6]=0x53544731;$w[7]=0x32303236;$w[8]=0x31303033
  $w[9]=1;$w[10]=2;$w[11]=3;$w[12]=4;$w[13]=7;$w[14]=1;$w[16]=0x123;$w[17]=0x52190000;$w[18]=8000000
  $w[20]=1;$w[21]=3178;$w[22]=7;$w[23]=1;$w[24]=13;$w[25]=106;$w[26]=1;$w[27]=1
  $w[28]=4810000;$w[30]=4900000;$w[32]=4916000;$w[34]=21;$w[35]=21
  $w[36]=1;$w[37]=31;$w[38]=7;$w[39]=1;$w[40]=5;$w[41]=106;$w[42]=1;$w[43]=4810;$w[44]=4900;$w[46]=90;$w[48]=15;$w[49]=1;$w[50]=31;$w[52]=98;$w[53]=98;$w[56]=4;$w[57]=4900;$w[58]=4900;$w[59]=1;$w[60]=4900001
  $f['first_usb_failure_first_read_base64']=[Convert]::ToBase64String((Pack-Words $w));$f['first_usb_failure_second_read_base64']=$f.first_usb_failure_first_read_base64
  $f
}
$fiveNm=$goodNm+"`n3fcab400 00000180 B vc_lora_r19_first_usb_failure_record`n"
Check 'v5-binds-fifth-384-byte-record-with-independent-decoder-pin' {
  $c=New-FirstFailureCandidate 'v5-binding';[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$fiveNm)
  try { $b=Bind $c;Require ($b.first_usb_failure_enabled -and $b.first_usb_failure_address-eq'0x3fcab400' -and @($b.symbols.Keys).Count-eq5) 'new record binding absent' }
  finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
}
foreach($mutation in @('missing-first-symbol','duplicate-first-symbol','short-first-symbol','overlap-first','partial-v5','downgrade-reader','missing-decoder-pin','bad-decoder-pin','mixed-extension-version','missing-decoder-source','wrong-decoder-source-size','missing-sealed-decoder','changed-sealed-decoder','wrong-case-decoder-name','wrong-case-reader-name','wrong-case-extension-name')) {
  Check ('v5-reject-'+$mutation) {
    $c=New-FirstFailureCandidate ('v5-'+$mutation);$n=$fiveNm
    switch($mutation){
      'missing-first-symbol'{$n=$goodNm}
      'duplicate-first-symbol'{$n+="`n3fcab800 00000180 B vc_lora_r19_first_usb_failure_record`n"}
      'short-first-symbol'{$n=$n-replace'3fcab400 00000180','3fcab400 0000017c'}
      'overlap-first'{$n=$n-replace'3fcab400','3fcab300'}
      'partial-v5'{$c.seal.usb_extended_diagnostics.records.Remove('first_usb_failure')}
      'downgrade-reader'{$c.manifest.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v4'}
      'missing-decoder-pin'{$c.manifest.Remove('first_usb_failure_decoder')}
      'bad-decoder-pin'{$c.seal.first_usb_failure_decoder.sha256='0'*64}
      'mixed-extension-version'{$c.handoff.usb_extended_diagnostics.schema='vc-lora-r19-usb-extended-diagnostics-v1'}
      'missing-decoder-source'{$c.manifest.canonical_source_snapshot.files=@()}
      'wrong-decoder-source-size'{$c.manifest.canonical_source_snapshot.files[0].size_bytes=1}
      'missing-sealed-decoder'{Remove-Item -LiteralPath (Join-Path $c.root 'evidence/tools/read_r19_first_usb_failure_record.ps1')}
      'changed-sealed-decoder'{[IO.File]::WriteAllText((Join-Path $c.root 'evidence/tools/read_r19_first_usb_failure_record.ps1'),'throw "untrusted decoder"')}
      'wrong-case-decoder-name'{$v=$c.manifest.first_usb_failure_decoder;$c.manifest.Remove('first_usb_failure_decoder');$c.manifest['First_Usb_Failure_Decoder']=$v}
      'wrong-case-reader-name'{$v=$c.manifest.reader_schema;$c.manifest.Remove('reader_schema');$c.manifest['Reader_Schema']=$v}
      'wrong-case-extension-name'{$v=$c.manifest.usb_extended_diagnostics;$c.manifest.Remove('usb_extended_diagnostics');$c.manifest['Usb_Extended_Diagnostics']=$v}
    }
    Save-Candidate $c;[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$n)
    try{Reject{Bind $c}}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
  }
}
Check 'v4-rejects-undeclared-fifth-symbol' {
  $c=New-Candidate 'v4-stray-first';[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$fiveNm)
  try{Reject{Bind $c}}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
}
foreach($nmClass in @('D','R','T')){
  Check ('v4-rejects-undeclared-fifth-symbol-class-'+$nmClass) {
    $c=New-Candidate ('v4-non-b-first-'+$nmClass)
    $n=$goodNm+"`n3fcab400 00000180 $nmClass vc_lora_r19_first_usb_failure_record`n"
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$n)
    try{Reject{Bind $c}}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
  }
}
foreach($variant in @('v4-A-without-size','v4-D-without-size','v3-A-without-size','v5-B-plus-A-without-size','v5-B-without-size')){
  Check ('reject-defined-extension-size-omission-'+$variant) {
    $c=if($variant-like'v5-*'){New-FirstFailureCandidate ('size-omitted-'+$variant)}elseif($variant-like'v3-*'){New-Candidate ('size-omitted-'+$variant) $false}else{New-Candidate ('size-omitted-'+$variant)}
    $n=if($variant-like'v5-*'){$fiveNm}elseif($variant-like'v3-*'){(($goodNm-split"`r?`n"|Select-Object -First 2)-join"`n")}else{$goodNm}
    if($variant-ceq'v5-B-without-size'){$n=$n-replace'3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab400 B vc_lora_r19_first_usb_failure_record'}
    else{$class=if($variant-ceq'v4-D-without-size'){'D'}else{'A'};$n+="`n3fcab800 $class vc_lora_r19_first_usb_failure_record`n"}
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$n)
    try{Reject{Bind $c}}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
  }
}
Check 'mocked-live-v5-has-ten-stable-raws-in-one-smp-halt' {
  & {
    $c=New-FirstFailureCandidate 'v5-mocked-live';[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$fiveNm)
    try{$b=Bind $c}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
    $fixture=New-FirstFailureFixture
    $ScriptsRoot=$OutputRoot;$OpenOcdExecutable=$reader;$OpenOcdSha256=Get-Sha256 $reader
    $InterfaceConfig=$reader;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$reader;$TargetConfigSha256=$OpenOcdSha256
    $ProbeSerial='1c:db:d4:5a:83:80';$ProbeUsbLocation='1-4.4'
    function Invoke-NativeProcessCapture {
      param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
      $command=$Arguments-join"`n"
      Require (@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1) 'v5 must halt only once'
      $dumpMatches=[regex]::Matches($command,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
      Require ($dumpMatches.Count-eq10) 'v5 requires ten raw dumps'
      Require ($command.IndexOf('VC_LORA_JTAG_IDENTITY_MATCHED')-lt$command.IndexOf("`nhalt`n")-and$command.IndexOf('VC_LORA_HALT_CURSTATE_CPU1')-lt$command.IndexOf('dump_image')) 'v5 must bind identity and halt both cores first'
      Require ($command.LastIndexOf('dump_image')-lt$command.IndexOf('catch { resume }')) 'v5 dump occurs after resume'
      $ordinal=0
      foreach($m in $dumpMatches){
        $record=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure')[$ordinal%5]
        $sample=if($ordinal-lt5){'first'}else{'second'};$bytes=[Convert]::FromBase64String($fixture[$record+'_'+$sample+'_read_base64'])
        Require ([int]$m.Groups[3].Value-eq$bytes.Length) 'v5 size/order mismatch';[IO.File]::WriteAllBytes($m.Groups[1].Value,$bytes);++$ordinal
      }
      @('VC_LORA_JTAG_OPEN_SERIAL=1c:db:d4:5a:83:80','VC_LORA_JTAG_OPEN_LOCATION=1-4.4','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')|Set-Content -LiteralPath $LogPath
      [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
    }
    function Invoke-OpenOcdCleanup {[pscustomobject]@{required=$true;attempted=$true;exit_code=0;process_termination_proven=$true;resume_shutdown_proven=$true}}
    $raw=Read-LiveStageRecord -Artifact $b -OutputDirectory $OutputRoot -Attempt 1
    Require ($raw.smp_capture_proven-and$raw.cleanup.resume_shutdown_proven-and$raw.first_usb_failure_first.Length-eq384-and$raw.first_usb_failure_second.Length-eq384) 'v5 same-halt/cleanup/raw missing'
    $d=Decode-FirstUsbFailureRecord $raw.first_usb_failure_first $raw.first_usb_failure_second 'ground' $b.first_usb_failure_decoder.sha256
    Require ($d.failure_latched-and$d.first_failure.failure_observed_us-ceq'4900001'-and$d.boot_instance[0]-eq1) 'v5 full first failure lost'
  }
}
Check 'verified-decoder-bytes-not-reread-after-hash' {
  & {
    $original=$script:R19FirstFailureDecoderPath
    $copy=Join-Path $OutputRoot 'decoder-snapshot.ps1';Copy-Item -LiteralPath $original -Destination $copy
    $script:R19FirstFailureDecoderPath=$copy
    try{
      $c=New-FirstFailureCandidate 'v5-toctou';[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$fiveNm)
      try{$b=Bind $c}finally{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$goodNm)}
      [IO.File]::WriteAllText($copy,'throw "must never execute reread content"')
      $f=New-FirstFailureFixture
      $d=Decode-FirstUsbFailureRecord ([Convert]::FromBase64String($f.first_usb_failure_first_read_base64)) ([Convert]::FromBase64String($f.first_usb_failure_second_read_base64)) 'ground' $b.first_usb_failure_decoder.sha256
      Require $d.failure_latched 'verified decoder bytes were not retained'
    }finally{$script:R19FirstFailureDecoderPath=$original}
  }
}
foreach($mutation in @('valid-v5','valid-v5-offline-only','first-active','first-odd','first-unstable','first-short','first-wrong-role','first-wrong-fingerprint','first-zero-boot','first-unknown-sdk-mask','first-missing-second','v4-undeclared-first')) {
  Check ('v5-offline-'+$mutation) {
    $fixture=New-FirstFailureFixture
    switch($mutation){
      'first-active'{Set-Word $fixture 'first_usb_failure' 0 1}
      'first-odd'{Set-Word $fixture 'first_usb_failure' 1 7}
      'first-unstable'{Set-Word $fixture 'first_usb_failure' 1 8 -FirstOnly}
      'first-short'{$fixture.first_usb_failure_first_read_base64=[Convert]::ToBase64String([byte[]]::new(380))}
      'first-wrong-role'{Set-Word $fixture 'first_usb_failure' 4 2}
      'first-wrong-fingerprint'{Set-Word $fixture 'first_usb_failure' 5 1}
      'first-zero-boot'{foreach($i in 9..12){Set-Word $fixture 'first_usb_failure' $i 0}}
      'first-unknown-sdk-mask'{Set-Word $fixture 'first_usb_failure' 56 256}
      'first-missing-second'{$fixture.Remove('first_usb_failure_second_read_base64')}
      'v4-undeclared-first'{$fixture.schema='vc-lora-r19-usb-extended-jtag-fixture-v1'}
    }
    $case=Join-Path $OutputRoot ('v5-offline-'+$mutation);New-Item -ItemType Directory -Path $case -Force|Out-Null
    $fixturePath=Join-Path $case 'fixture.json';Json-Write $fixture $fixturePath
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$reader+'"'),'-FixturePath',('"'+$fixturePath+'"'),'-OutputRoot',('"'+(Join-Path $case 'read')+'"'))
    if($mutation-ceq'valid-v5-offline-only'){$arguments+=@('-OfflineExtendedRecordFixtureOnly')}
    $p=Start-Process -FilePath $shellPath -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $case 'stdout.txt') -RedirectStandardError (Join-Path $case 'stderr.txt')
    $summary=Get-Content -LiteralPath (Join-Path $case 'read/summary.json') -Raw|ConvertFrom-Json
    if($mutation-in@('valid-v5','valid-v5-offline-only')){
      $expectedSchema=if($mutation-ceq'valid-v5'){'vc-lora-r19-runtime-stage-jtag-read-v5'}else{'vc-lora-r19-usb-extended-offline-read-v2'}
      Require ($p.ExitCode-eq0-and$summary.schema-ceq$expectedSchema-and@($summary.reads).Count-eq10-and$summary.decoded.first_usb_failure.first_failure.failure_observed_us-ceq'4900001') 'v5 raw/decoded summary missing'
      $ordinal=0;foreach($read in $summary.reads){Require ($read.record-ceq@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure')[$ordinal%5]) 'v5 raw order wrong';Require ((Get-Sha256 $read.path)-ceq$read.sha256) 'v5 raw digest wrong';++$ordinal}
    }else{Require ($p.ExitCode-ne0-and$summary.result-ceq'FAIL'-and-not$summary.hardware_interaction) 'invalid v5 admitted'}
  }
}
$failed=@($checks|Where-Object{-not $_.passed})
$summary=[ordered]@{schema='vc-lora-r19-usb-extended-live-reader-contract-v1';result=$(if($failed.Count){'FAIL'}else{'PASS'});hardware_interaction=$false;passed_count=$checks.Count-$failed.Count;failed_count=$failed.Count;checks=@($checks)}
Json-Write $summary (Join-Path $OutputRoot 'summary.json'); $summary|ConvertTo-Json -Depth 10
if($failed.Count){exit 1}
