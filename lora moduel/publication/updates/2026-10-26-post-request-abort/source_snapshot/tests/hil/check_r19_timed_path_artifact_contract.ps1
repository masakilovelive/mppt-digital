[CmdletBinding()]
param([string]$RepoRoot='',[string]$FirmwareFixtureRoot='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
Check ((Get-R19CandidateOutputLeaf $true 'SyncOnly') -ceq 'R19-TIMED-PATH-SYNC-ONLY-DIAGNOSTIC-CANDIDATE-BUILD-001') 'SyncOnly must have isolated output'
Check ((Get-R19CandidateOutputLeaf $true 'ExplicitHostArm') -ceq 'R19-TIMED-PATH-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001') 'ExplicitHostArm must have isolated output'
Check ((Get-R19CandidateOutputLeaf $true) -ceq 'R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001') 'Legacy diagnostic output must be unchanged'
Reject {Get-R19CandidateOutputLeaf $false 'SyncOnly'} 'Timed mode without diagnostic macro must reject'
$contract=Get-R19TimedPathCandidateContract $RepoRoot 'ExplicitHostArm'
Check ($contract.mode_value-eq2-and$contract.record.size_bytes-eq512-and$contract.record.symbol-ceq'vc_lora_r19_timed_path_record') 'Exact timed ABI binding'
Check ($contract.decoder.sha256-cmatch'^[A-F0-9]{64}$') 'Decoder fingerprint required'
. (Join-Path $RepoRoot 'tools/read_r19_timed_path_record.ps1')
[uint32[]]$w=New-Object uint32[] 128
$w[1]=2;$w[2]=0x52313954;$w[3]=1;$w[4]=1;$w[5]=7;$w[9]=9;$w[13]=1;$w[14]=2
function Bytes([uint32[]]$Words){[byte[]]$b=New-Object byte[] 512;for($i=0;$i-lt128;$i++){[BitConverter]::GetBytes($Words[$i]).CopyTo($b,$i*4)};return ,$b}
$b=Bytes $w
$d=ConvertFrom-R19TimedPathRecord -First $b -Second $b -ExpectedRole ground -ExpectedMode ExplicitHostArm
Check ($d.role-ceq'ground'-and$d.mode-ceq'ExplicitHostArm'-and$d.product_budget_ms-eq0) 'Initialized-only record has no invented product budget'
Check ($d.acceptance_authorized-eq$false-and$d.root_cause_proven-eq$false) 'Decoder cannot authorize acceptance'
$bad=$b.Clone();$bad[4]=3;Reject {ConvertFrom-R19TimedPathRecord $bad $bad ground ExplicitHostArm} 'Odd seqlock rejects'
$bad=$b.Clone();$bad[100]=1;Reject {ConvertFrom-R19TimedPathRecord $b $bad ground ExplicitHostArm} 'Unstable pair rejects'
Reject {ConvertFrom-R19TimedPathRecord $b $b vehicle ExplicitHostArm} 'Wrong role rejects'
Reject {ConvertFrom-R19TimedPathRecord $b $b ground SyncOnly} 'Wrong mode rejects'
$bad=$w.Clone();$bad[24]=500;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'Product budget cannot become diagnostic500'
$bad=$w.Clone();$bad[51]=1;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'Reserved words reject'
$bad=$w.Clone();$bad[13]=193;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'Both terminals reject'
$bad=$w.Clone();$bad[46]=256;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'Unknown SDK validity rejects even on absent stage'
$bad=$w.Clone();$bad[32]=99;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'SDK timestamp cannot exist without observed SDK stage'
$bad=$w.Clone();$bad[26]=99;$bb=Bytes $bad;Reject {ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm} 'ARM timestamp cannot exist without accepted ARM'
$vehicle=$w.Clone();$vehicle[4]=2;$bb=Bytes $vehicle;$v=ConvertFrom-R19TimedPathRecord $bb $bb vehicle ExplicitHostArm;Check (-not$v.frame_enqueued-and$v.product_budget_ms-eq0) 'Vehicle initialized-only record decodes without fabricated frame'
$tainted=$w.Clone();$tainted[13]=513;$bb=Bytes $tainted;$t=ConvertFrom-R19TimedPathRecord $bb $bb ground ExplicitHostArm;Check ($t.clock_regressed-and-not$t.root_cause_proven) 'Clock taint remains a decodable diagnostic not causal proof'
if($FirmwareFixtureRoot){
  foreach($name in @('ground_failed','ground_completed','ground_no_frame','vehicle_no_frame')){
    $role=if($name.StartsWith('vehicle')){'vehicle'}else{'ground'}
    [byte[]]$actual=[IO.File]::ReadAllBytes((Join-Path $FirmwareFixtureRoot ($name+'.bin')))
    $record=ConvertFrom-R19TimedPathRecord $actual $actual $role ExplicitHostArm
    Check ($record.size_bytes-eq512-and$record.role-ceq$role-and$record.build_id.Count-eq4-and$record.boot_id.Count-eq4) 'Actual C++ initialized record matches exact decoder ABI'
    if($name-ceq'ground_failed'){
      Check ($record.usb_failed-and$record.frame_bytes-eq21-and$record.accepted_bytes-eq21-and$record.sdk.publish_generation-eq3-and$record.sdk.pickup_generation-eq2) 'Actual C++ failure snapshot counts preserved'
      Check ($record.timestamps.arm_us-ceq'1311768464867721226'-and$record.timestamps.failure_returned_us-ceq'1311768464867827216') 'Actual C++ uint64 times survive above IEEE754 precision'
    }elseif($name.EndsWith('no_frame')){Check (-not$record.frame_enqueued-and$record.product_budget_ms-eq0) 'Actual C++ no-frame record does not fabricate USB stages'}
    else{Check ($record.usb_completed-and-not$record.usb_failed) 'Actual C++ completion stays separate from failure'}
  }
}
$build=Get-Content (Join-Path $RepoRoot 'tools/build_r19_candidate_artifacts.ps1') -Raw
$verify=Get-Content (Join-Path $RepoRoot 'tools/verify_r19_candidate_artifact.ps1') -Raw
$reader=Get-Content (Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1') -Raw
foreach($t in @($build,$verify)){Check ($t.Contains('TimedPathMode')) 'Builder/verifier explicit opt-in mode required';Check ($t.Contains('timed_path_diagnostics')) 'Builder/verifier mode contract required'}
Check ($reader.Contains('ConvertFrom-R19TimedPathRecord')-and$reader.Contains('timed_path_first.bin')-and$reader.Contains('timed_path_second.bin')) 'JTAG must decode two stable timed reads'
$artifactChecks=$checks
$repo=$RepoRoot
$tokens=$null;$errors=$null
$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($readerPath,[ref]$tokens,[ref]$errors)
foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$fixtures=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1'),[ref]$tokens,[ref]$errors)
foreach($f in $fixtures.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-in@('New-Candidate','New-FirstFailureCandidate','Save-Candidate','Json-Write')},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('r19-timed-artifact-contract-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$script:R19FirstFailureDecoderPath=Join-Path $RepoRoot 'tools/read_r19_first_usb_failure_record.ps1'
$script:R19TimedPathDecoderPath=Join-Path $RepoRoot 'tools/read_r19_timed_path_record.ps1'
$NmExecutable=Join-Path $OutputRoot 'mock-nm.ps1'
[IO.File]::WriteAllText($NmExecutable,'param($a,$b,$c);Get-Content (Join-Path $PSScriptRoot ''nm.txt'');$global:LASTEXITCODE=0')
$NmSha256=Get-Sha256 $NmExecutable
$nm=@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record','3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab600 00000200 B vc_lora_r19_timed_path_record')-join"`n"
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nm)
function New-TimedCandidate([string]$Name){
  $c=New-FirstFailureCandidate $Name
  $pin=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
  foreach($doc in @($c.manifest,$c.seal,$c.handoff)){$doc.timed_path_diagnostics=$pin;$doc.roles[0].runtime_diagnostic_symbols.symbols.timed_path=[ordered]@{name='vc_lora_r19_timed_path_record';address='0x3fcab600';size_bytes=512;aligned_32_bit=$true}}
  $property=Get-R19CandidateCompileProperty $true ExplicitHostArm
  $c.manifest.candidate_enable=[ordered]@{property=$property};$c.manifest.roles[0].compile=[ordered]@{argv=@($property)}
  $c.manifest.canonical_source_snapshot.files+=@([ordered]@{path=$pin.decoder.path;sha256=$pin.decoder.sha256;size_bytes=(Get-Item $script:R19TimedPathDecoderPath).Length})
  Copy-Item -LiteralPath $script:R19TimedPathDecoderPath -Destination (Join-Path $c.root 'evidence/tools/read_r19_timed_path_record.ps1')
  Save-Candidate $c
  return $c
}
function Bind-Timed($C){Assert-ArtifactBinding -Root $C.root -ExpectedArtifactId mock-candidate -ExpectedRole ground -ExpectedAddress ([uint32]0x3fcab000)}
$c=New-TimedCandidate 'positive';$bound=Bind-Timed $c
Check ($bound.timed_path_enabled-and$bound.timed_path_address-ceq'0x3fcab600'-and$bound.symbols.Count-eq6) 'Sixth symbol and mode bind to manifest seal handoff'
foreach($mutation in @('missing-mode','wrong-mode','wrong-size','bad-decoder','missing-sealed-decoder','missing-source','wrong-flag','undeclared-symbol')){
  $c=New-TimedCandidate $mutation
  switch($mutation){
    'missing-mode'{$c.seal.Remove('timed_path_diagnostics')}
    'wrong-mode'{$copy=$c.seal.timed_path_diagnostics|ConvertTo-Json -Depth 12|ConvertFrom-Json;$copy.mode='SyncOnly';$c.seal.timed_path_diagnostics=$copy}
    'wrong-size'{$c.manifest.timed_path_diagnostics.record.size_bytes=508}
    'bad-decoder'{$c.manifest.timed_path_diagnostics.decoder.sha256='0'*64}
    'missing-sealed-decoder'{Remove-Item -LiteralPath (Join-Path $c.root 'evidence/tools/read_r19_timed_path_record.ps1')}
    'missing-source'{$c.manifest.canonical_source_snapshot.files=@($c.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/read_r19_timed_path_record.ps1'})}
    'wrong-flag'{$c.manifest.roles[0].compile.argv=@('compiler.cpp.extra_flags=-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1')}
    'undeclared-symbol'{foreach($doc in @($c.manifest,$c.seal,$c.handoff)){$doc.Remove('timed_path_diagnostics')}}
  }
  Save-Candidate $c;Reject {Bind-Timed $c} "Timed artifact mutation admitted: $mutation"
}
$c=New-TimedCandidate 'mock-capture';$bound=Bind-Timed $c
& {
  $stageRecordBytes=68;$fifoRecordBytes=112;$ScriptsRoot=$OutputRoot;$OpenOcdExecutable=$readerPath;$OpenOcdSha256=Get-Sha256 $readerPath
  $InterfaceConfig=$readerPath;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$readerPath;$TargetConfigSha256=$OpenOcdSha256
  $ProbeSerial='1c:db:d4:5a:83:80';$ProbeUsbLocation='1-4.4'
  function Invoke-NativeProcessCapture{
    param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
    $cmd=$Arguments-join"`n";$dump=[regex]::Matches($cmd,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
    Check ($dump.Count-eq12-and@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1-and$cmd.LastIndexOf('dump_image')-lt$cmd.IndexOf('catch { resume }')) 'Twelve records require one SMP halt and precede resume'
    foreach($d in $dump){[IO.File]::WriteAllBytes($d.Groups[1].Value,(New-Object byte[] ([int]$d.Groups[3].Value)))}
    [IO.File]::WriteAllText($LogPath,(@('VC_LORA_JTAG_OPEN_SERIAL=1c:db:d4:5a:83:80','VC_LORA_JTAG_OPEN_LOCATION=1-4.4','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')-join"`n"))
    [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
  }
  function Invoke-OpenOcdCleanup{[pscustomobject]@{required=$true;attempted=$true;exit_code=0;timed_out=$false;process_termination_proven=$true;resume_shutdown_proven=$true}}
  $capture=Read-LiveStageRecord -Artifact $bound -OutputDirectory $OutputRoot -Attempt 1
  Check ($capture.timed_path_first.Length-eq512-and$capture.timed_path_second.Length-eq512) 'Both timed raw samples retained'
}
Write-Output "check_r19_timed_path_artifact_contract PASS checks=$checks hardware_interaction=false"
