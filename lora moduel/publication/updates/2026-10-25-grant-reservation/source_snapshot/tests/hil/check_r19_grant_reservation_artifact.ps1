[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputDirectory='', [string]$ActualManifestPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $RepoRoot 'tools/r19_candidate_artifact_common.ps1')
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw ('FAIL '+$Message)}}
function Reject([scriptblock]$Action,[string]$Message){$threw=$false;try{&$Action|Out-Null}catch{$threw=$true};Check $threw $Message}
$expectedLeaf='R19-GRANT-RESERVATION-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001'
Check ((Get-R19CandidateOutputLeaf $true ExplicitHostArm $true $true $true $true)-ceq$expectedLeaf) 'Reservation diagnostics require a separate explicitly selected candidate leaf'
Check ((Get-R19CandidateOutputLeaf $true ExplicitHostArm $true $true $true)-ceq'R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Default-off v9 leaf remains unchanged'
$flags=Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true $true
Check ($flags.EndsWith(' -DVC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS=1')) 'Reservation producer macro is explicit opt-in'
foreach($selection in @(@($false,'ExplicitHostArm',$true,$true,$true,$true),@($true,'SyncOnly',$true,$true,$true,$true),@($true,'ExplicitHostArm',$false,$true,$true,$true),@($true,'ExplicitHostArm',$true,$false,$true,$true),@($true,'ExplicitHostArm',$true,$true,$false,$true))){Reject {Get-R19CandidateOutputLeaf @selection} 'Partial reservation mode must reject'}
$contract=Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $true
Check ($null-eq(Get-R19GrantReservationCandidateContract -RepoRoot $RepoRoot -Enabled $false)) 'Default-off reservation contract is absent'
Check ($contract.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v10'-and$contract.record.size_bytes-eq512-and$contract.record.symbol-ceq'vc_lora_r19_grant_reservation_record') 'Reservation tenth-record ABI is exact'
$validated=Assert-R19GrantReservationCandidateContract -Value $contract -RepoRoot $RepoRoot -Enabled $true
Check ($validated.capture.prepare_seconds-eq15-and$validated.capture.measurement_seconds-eq40-and$validated.capture.param_request_maximum-eq1) 'Preparation and one40-second single-request measurement remain separate'
foreach($mutation in @('false','string-bool','extra','wrong-case','decoder-hash','record-size','reader','producer','prepare','measurement','wire-size','role-capabilities')){
  $bad=$contract|ConvertTo-Json -Depth 15|ConvertFrom-Json
  switch($mutation){
    'false'{$bad.enabled=$false}
    'string-bool'{$bad.enabled='true'}
    'extra'{$bad|Add-Member NoteProperty fake_future_plan $true}
    'wrong-case'{$v=$bad.enabled;$bad.PSObject.Properties.Remove('enabled');$bad|Add-Member NoteProperty Enabled $v}
    'decoder-hash'{$bad.decoder.sha256='0'*64}
    'record-size'{$bad.record.size_bytes=508}
    'reader'{$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
    'producer'{$bad.producer.kind='feasible-plan-only'}
    'prepare'{$bad.capture.prepare_seconds=16}
    'measurement'{$bad.capture.measurement_seconds=55}
    'wire-size'{$bad.usb_control.frame_bytes=63}
    'role-capabilities'{$bad.producer.role_capabilities.ground=@('TailPermit')}
  }
  Reject {Assert-R19GrantReservationCandidateContract -Value $bad -RepoRoot $RepoRoot -Enabled $true} ('Strict reservation sidecar rejects '+$mutation)
}
$verifierMain=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/verify_r19_candidate_artifact.ps1') -Raw
$provenanceStart=$verifierMain.IndexOf('$enable = $manifest.candidate_enable',[StringComparison]::Ordinal)
$provenanceEnd=$verifierMain.IndexOf('Assert-Condition ((@($manifest.compile_order)',$provenanceStart,[StringComparison]::Ordinal)
Check ($provenanceStart-ge0-and$provenanceEnd-gt$provenanceStart) 'Actual verifier main provenance slice is exact and bounded'
$provenanceCode=$verifierMain.Substring($provenanceStart,$provenanceEnd-$provenanceStart)
& {
  $runtimeFailDiagnosticsEnabled=$true;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm
  function Assert-Condition([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
  $manifest=[pscustomobject]@{candidate_enable=[pscustomobject][ordered]@{macro='VC_LORA_R19_HIGH_SPEED_CANDIDATE';value=1;compile_flag='-DVC_LORA_R19_HIGH_SPEED_CANDIDATE=1';property=Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true $true;bridge_default=0;mechanism='arduino-cli-build-property'}}
  . ([scriptblock]::Create($provenanceCode));Check $true 'Actual verifier main accepts truthful full reservation compiler provenance'
  $grantReservationEnabled=$false;Reject {. ([scriptblock]::Create($provenanceCode))} 'Actual verifier main rejects undeclared reservation compile macro'
  $grantReservationEnabled=$true;$manifest.candidate_enable.property+=' -DUNREVIEWED_EXTRA_FLAG=1'
  Reject {. ([scriptblock]::Create($provenanceCode))} 'Actual verifier main rejects extra compiler flags rather than loosening equality'
  if($ActualManifestPath){
    $before=(Get-FileHash -LiteralPath $ActualManifestPath -Algorithm SHA256).Hash
    $manifest=Get-Content -LiteralPath $ActualManifestPath -Raw|ConvertFrom-Json
    . ([scriptblock]::Create($provenanceCode))
    foreach($role in @($manifest.roles)){Check (@($role.compile.argv)-ccontains$expectedCompileProperty) ('Actual immutable compiler argv binds full provenance '+$role.role)}
    Check ((Get-FileHash -LiteralPath $ActualManifestPath -Algorithm SHA256).Hash-ceq$before) 'Actual failed candidate manifest is read-only and unchanged'
  }
}
foreach($relative in @('tools/build_r19_candidate_artifacts.ps1','tools/verify_r19_candidate_artifact.ps1')){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $relative),[ref]$tokens,[ref]$errors)
  $initializer=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$grantReservationContract'})
  Check ($initializer.Count-eq1) ('One reservation initializer '+$relative)
  & {
    $grantReservationEnabled=$false
    $repo=$RepoRoot
    function Get-R19GrantReservationCandidateContract {throw 'Disabled reservation must not require a new staged module'}
    . ([scriptblock]::Create($initializer[0].Extent.Text))
    Check ($null-eq$grantReservationContract) ('Legacy staged closure has no new module dependency '+$relative)
  }
}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
$tools=@(Get-R19TimedPathOuterToolPaths $true $true $true $true $true)
Check ($tools.Count-eq26-and@($tools|Select-Object -Unique).Count-eq26) 'Reservation mode binds exactly 26 distinct tools'
Reject {Get-R19TimedPathOuterToolPaths $true $true $false $true $true} 'Reservation cannot omit single-parameter request mode'
foreach($file in @('tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1','tools/invoke_r19_candidate_app_flash_hil.ps1','tools/invoke_r19_jtag_preflash_gate.ps1')){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $file),[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('PowerShell syntax remains valid: '+$file)
  Check (@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath-ceq'GrantReservationDiagnostics'}).Count-eq1) ('Explicit reservation switch propagated: '+$file)
}
. (Join-Path $RepoRoot 'tools/read_r19_grant_reservation_record.ps1') -ImportOnly
function Bytes([uint32[]]$Words){[byte[]]$result=New-Object byte[] ($Words.Count*4);for($i=0;$i-lt$Words.Count;$i++){[BitConverter]::GetBytes($Words[$i]).CopyTo($result,$i*4)};return ,$result}
[uint32[]]$words=New-Object uint32[] 128
$words[1]=2;$words[2]=0x52313952;$words[3]=1;$words[4]=1
$words[5]=1;$words[6]=2;$words[7]=3;$words[8]=4
$words[9]=5;$words[10]=6;$words[11]=7;$words[12]=8
$words[13]=1;$words[14]=512;$words[18]=5;$words[19]=6
$raw=Bytes $words
$decoded=ConvertFrom-R19GrantReservationRecord -First $raw -Second $raw -ExpectedRole ground -ExpectedFingerprint ([uint32[]]@(1,2,3,4)) -ExpectedBoot ([uint32[]]@(5,6,7,8))
Check ($decoded.schema-ceq'vc-lora-r19-grant-reservation-decoded-v1'-and$decoded.role-ceq'ground') 'Actual paired 512-byte decoder roundtrip binds role/build/boot'
foreach($mutation in @('size','writer','sequence','magic','schema','role','flags','reserved','count','state','reason','own-boot')){
  $badWords=[uint32[]]$words.Clone()
  switch($mutation){'size'{$badWords[14]=508};'writer'{$badWords[0]=1};'sequence'{$badWords[1]=3};'magic'{$badWords[2]=0};'schema'{$badWords[3]=2};'role'{$badWords[4]=2};'flags'{$badWords[13]=9};'reserved'{$badWords[31]=1};'count'{$badWords[16]=1};'state'{$badWords[15]=15};'reason'{$badWords[15]=22*65536};'own-boot'{$badWords[18]=99}}
  $badRaw=Bytes $badWords
  Reject {ConvertFrom-R19GrantReservationRecord -First $badRaw -Second $badRaw -ExpectedRole ground} ('Decoder rejects '+$mutation)
}
Reject {ConvertFrom-R19GrantReservationRecord -First $raw -Second (New-Object byte[] 512) -ExpectedRole ground} 'Decoder rejects changing paired samples'
Write-Output "check_r19_grant_reservation_artifact PASS checks=$script:checks hardware_interaction=false"
function Import-Definitions([string]$Relative,[string[]]$Names){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Relative),[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('Parse imported pure definitions '+$Relative)
  foreach($node in $ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and($Names.Count-eq0-or$_.Name-cin$Names)}){
    . ([scriptblock]::Create($node.Extent.Text));Set-Item -Path ('Function:script:'+$node.Name) -Value (Get-Item ('Function:'+$node.Name)).ScriptBlock
  }
}
Import-Definitions 'tools/read_r19_runtime_stage_jtag.ps1' @()
Import-Definitions 'tests/arduino_compile/check_r19_usb_extended_live_reader_contract.ps1' @('New-Candidate','New-FirstFailureCandidate','Save-Candidate','Json-Write')
Import-Definitions 'tests/hil/check_r19_aux_readiness_artifact.ps1' @('New-AuxCandidate')
Import-Definitions 'tests/hil/check_r19_diagnostic_usb_failure_record.ps1' @('Pack','NewV8Fixture','NewV8Candidate')
Import-Definitions 'tests/hil/check_r19_grant_artifact_contract.ps1' @('NewV9Fixture','NewV9Candidate')
if(-not$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/fixtures-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$fixtureRoot=$OutputDirectory;$OutputRoot=Join-Path $OutputDirectory 'sealed';[void][IO.Directory]::CreateDirectory($OutputRoot)
$repo=$RepoRoot;$readerPath=Join-Path $RepoRoot 'tools/read_r19_runtime_stage_jtag.ps1'
foreach($spec in @(@('R19FirstFailureDecoderPath','read_r19_first_usb_failure_record.ps1'),@('R19TimedPathDecoderPath','read_r19_timed_path_record.ps1'),@('R19AuxReadinessDecoderPath','read_r19_aux_readiness_record.ps1'),@('R19DiagnosticUsbFailureDecoderPath','read_r19_diagnostic_usb_failure_record.ps1'),@('R19GrantDiagnosticDecoderPath','read_r19_grant_diagnostic_record.ps1'),@('R19GrantReservationDecoderPath','read_r19_grant_reservation_record.ps1'))){Set-Variable -Scope Script -Name $spec[0] -Value (Join-Path $RepoRoot ('tools/'+$spec[1]))}
$NmExecutable=Join-Path $OutputRoot 'mock-nm.ps1'
[IO.File]::WriteAllText($NmExecutable,'param($a,$b,$c);Get-Content (Join-Path $PSScriptRoot ''nm.txt'');$global:LASTEXITCODE=0')
$NmSha256=Get-Sha256 $NmExecutable
$nmTen=@('3fcab000 00000044 B vc_lora_r19_runtime_stage_record','3fcab100 00000070 B vc_lora_r19_hwcdc_fifo_diagnostic_record','3fcab200 00000080 B vc_lora_r19_hwcdc_restart_diagnostic_record','3fcab300 00000080 B vc_lora_r19_ground_usb_commit_record','3fcab400 00000180 B vc_lora_r19_first_usb_failure_record','3fcab600 00000200 B vc_lora_r19_timed_path_record','3fcac000 00001800 B vc_lora_r19_aux_readiness_record','3fcad800 00000100 B vc_lora_r19_diagnostic_usb_failure_record','3fcadc00 00000400 B vc_lora_r19_grant_diagnostic_record','3fcae000 00000200 B vc_lora_r19_grant_reservation_record')-join"`n"
function NewV10Candidate([string]$Name){
  $c=NewV9Candidate $Name;$pin=Get-R19GrantReservationCandidateContract $RepoRoot $true
  foreach($doc in @($c.manifest,$c.seal,$c.handoff)){
    $doc.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10';$doc.grant_reservation_diagnostics=$pin
    $doc.roles[0].runtime_diagnostic_symbols.symbols.grant_reservation=[ordered]@{name='vc_lora_r19_grant_reservation_record';address='0x3fcae000';size_bytes=512;aligned_32_bit=$true}
  }
  $flag=Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true $true
  $c.manifest.candidate_enable.property=$flag;$c.manifest.roles[0].compile.argv=@($flag)
  foreach($relative in @('firmware/high_speed/r19_grant_reservation.hpp','firmware/high_speed/r19_grant_reservation_record.hpp','tools/read_r19_grant_reservation_record.ps1','tools/r19_grant_reservation_contract.ps1','tools/r19_grant_reservation_wire.ps1','tools/r19_grant_reservation_workflow.ps1')){
    $path=Join-Path $RepoRoot $relative
    $c.manifest.canonical_source_snapshot.files+=@([ordered]@{path=$relative;sha256=Get-Sha256 $path;size_bytes=(Get-Item -LiteralPath $path).Length})
    if($relative.StartsWith('tools/')){Copy-Item -LiteralPath $path -Destination (Join-Path $c.root ('evidence/'+$relative))}
  }
  Save-Candidate $c;return $c
}
function BindV10($Candidate){Assert-ArtifactBinding -Root $Candidate.root -ExpectedArtifactId mock-candidate -ExpectedRole ground -ExpectedAddress ([uint32]0x3fcab000)}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmTen)
$candidate=NewV10Candidate 'positive-ten';$bound=BindV10 $candidate
Check ($bound.grant_reservation_enabled-and$bound.symbols.Count-eq10-and$bound.grant_reservation_address-ceq'0x3fcae000') 'Actual sealed v10 candidate binds ten symbols and reservation capability'
foreach($mutation in @('missing-seal','reader','missing-symbol','size','storage','overlap','source','decoder','macro','wrong-case','producer')){
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmTen);$c=NewV10Candidate ('reject-ten-'+$mutation)
  switch($mutation){
    'missing-seal'{$c.seal.Remove('grant_reservation_diagnostics')}
    'reader'{$c.handoff.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
    'missing-symbol'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),(($nmTen-split"`n"|Where-Object{$_-notmatch'grant_reservation_record'})-join"`n"))}
    'size'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmTen.Replace('00000200 B vc_lora_r19_grant_reservation','000001fc B vc_lora_r19_grant_reservation'))}
    'storage'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmTen.Replace('00000200 B vc_lora_r19_grant_reservation','00000200 D vc_lora_r19_grant_reservation'))}
    'overlap'{[IO.File]::WriteAllText((Join-Path $OutputRoot 'nm.txt'),$nmTen.Replace('3fcae000','3fcadd00'))}
    'source'{$c.manifest.canonical_source_snapshot.files=@($c.manifest.canonical_source_snapshot.files|Where-Object{$_.path-cne'tools/r19_grant_reservation_workflow.ps1'})}
    'decoder'{[IO.File]::WriteAllText((Join-Path $c.root 'evidence/tools/read_r19_grant_reservation_record.ps1'),'not sealed bytes')}
    'macro'{$c.manifest.roles[0].compile.argv=@((Get-R19CandidateCompileProperty $true ExplicitHostArm $true $true $true))}
    'wrong-case'{$v=$c.manifest.grant_reservation_diagnostics;$c.manifest.Remove('grant_reservation_diagnostics');$c.manifest.Grant_Reservation_Diagnostics=$v}
    'producer'{$c.manifest.grant_reservation_diagnostics.producer.kind='feasible-plan-only'}
  }
  Save-Candidate $c;Reject {BindV10 $c} ('Actual v10 sealed candidate rejects '+$mutation)
}
function NewV10Fixture([string]$Role='ground'){
  $f=NewV9Fixture $Role;$f.schema='vc-lora-r19-usb-extended-jtag-fixture-v10';$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v10'
  $f.grant_reservation_diagnostics=Get-R19GrantReservationCandidateContract $RepoRoot $true
  [uint32[]]$w=New-Object uint32[] 128;$w[1]=2;$w[2]=0x52313952;$w[3]=1;$w[4]=if($Role-ceq'ground'){1}else{2};$w[13]=1;$w[14]=512
  for($i=0;$i-lt4;$i++){$w[5+$i]=[uint32]@(0x52313944,0x53544731,0x32303236,0x31303033)[$i];$w[9+$i]=[uint32](1+$i)}
  $w[18]=1;$w[19]=2
  $f.grant_reservation_address='0x3fcae000';$f.grant_reservation_first_read_base64=[Convert]::ToBase64String((Pack $w));$f.grant_reservation_second_read_base64=$f.grant_reservation_first_read_base64
  return $f
}
$shellPath=if($PSVersionTable.PSEdition-ceq'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
function RunV10Fixture([string]$Name,$Fixture,[bool]$Pass){
  $caseRoot=Join-Path $fixtureRoot $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
  $path=Join-Path $caseRoot 'fixture.json';[IO.File]::WriteAllText($path,($Fixture|ConvertTo-Json -Depth 25))
  & $shellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $readerPath -OfflineExtendedRecordFixtureOnly -FixturePath $path -OutputRoot (Join-Path $caseRoot 'read') *> (Join-Path $caseRoot 'reader.log')
  $code=$LASTEXITCODE;$result=Get-Content -LiteralPath (Join-Path $caseRoot 'read/summary.json') -Raw|ConvertFrom-Json
  Check $(if($Pass){$code-eq0-and$result.result-ceq'PASS'-and@($result.reads).Count-eq20-and$result.schema-ceq'vc-lora-r19-usb-extended-offline-read-v10'-and$result.decoded.grant_reservation.expected_identity_bound}else{$code-ne0-and$result.result-ceq'FAIL'}) ('Actual v10 fixture '+$Name)
  return $result
}
$null=RunV10Fixture 'ground-twenty' (NewV10Fixture ground) $true
$null=RunV10Fixture 'vehicle-twenty' (NewV10Fixture vehicle) $true
foreach($mutation in @('schema','missing','pair','overlap','boot','build','capability')){
  $f=NewV10Fixture
  switch($mutation){
    'schema'{$f.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'}
    'missing'{$f.Remove('grant_reservation_second_read_base64')}
    'pair'{$b=[Convert]::FromBase64String($f.grant_reservation_first_read_base64);$b[64]=1;$f.grant_reservation_first_read_base64=[Convert]::ToBase64String($b)}
    'overlap'{$f.grant_reservation_address='0x3fcadd00'}
    'boot'{foreach($sample in @('first','second')){$key='grant_reservation_'+$sample+'_read_base64';$b=[Convert]::FromBase64String($f[$key]);$b[36]=99;$f[$key]=[Convert]::ToBase64String($b)}}
    'build'{foreach($sample in @('first','second')){$key='grant_reservation_'+$sample+'_read_base64';$b=[Convert]::FromBase64String($f[$key]);$b[20]=99;$f[$key]=[Convert]::ToBase64String($b)}}
    'capability'{$f.grant_reservation_diagnostics.producer.kind='fake-plan'}
  }
  $null=RunV10Fixture ('reject-fixture-'+$mutation) $f $false
}
Write-Output "check_r19_grant_reservation_artifact FINAL_PASS checks=$script:checks hardware_interaction=false"
Import-Definitions 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1' @('Assert-Condition','Assert-RawProjection','Get-GrantReservationRawReplay','Assert-CandidateDiagnosticAbiContract')
& {
  $candidateFixture=NewV10Candidate 'parent-raw-replay';$candidate=[pscustomobject]@{artifact_root=$candidateFixture.root}
  $f=NewV10Fixture;$evidenceRoot=Join-Path $fixtureRoot 'parent-paired-raw';[void][IO.Directory]::CreateDirectory($evidenceRoot)
  $record=$candidateFixture.seal.roles[0].runtime_diagnostic_symbols|ConvertTo-Json -Depth 20|ConvertFrom-Json
  $data=[Convert]::FromBase64String($f.grant_reservation_first_read_base64)
  $reads=@(1..18|ForEach-Object{[pscustomobject]@{}})
  foreach($sample in 1,2){$suffix=if($sample-eq1){'first'}else{'second'};$path=Join-Path $evidenceRoot ('grant_reservation_'+$suffix+'.bin');[IO.File]::WriteAllBytes($path,$data);$reads+=,[pscustomobject]@{record='grant_reservation';sample=$sample;size_bytes=512;path=$path;sha256=Get-Sha256 $path}}
  [uint32[]]$legacy=New-Object uint32[] 17;for($i=0;$i-lt4;$i++){$legacy[5+$i]=[uint32]@(0x52313944,0x53544731,0x32303236,0x31303033)[$i]}
  $firstFailure=[pscustomobject]@{boot_instance=[uint32[]]@(1,2,3,4)}
  $decoded=ConvertFrom-R19GrantReservationRecord -First $data -Second $data -ExpectedRole ground -ExpectedFingerprint ([uint32[]]$legacy[5..8]) -ExpectedBoot $firstFailure.boot_instance
  $summary=[pscustomobject]@{schema='vc-lora-r19-runtime-stage-jtag-read-v10';grant_reservation_required=$true;reads=$reads;decoded=[pscustomobject]@{grant_reservation=$decoded};binding=[pscustomobject]@{grant_reservation_diagnostics=$f.grant_reservation_diagnostics;grant_reservation_address='0x3fcae000';artifact=[pscustomobject]@{grant_reservation_enabled=$true;grant_reservation_diagnostics=$f.grant_reservation_diagnostics;symbols=$record.symbols}}}
  function ParentReplay($value){Get-GrantReservationRawReplay -Summary $value -Role ground -EvidenceDirectory $evidenceRoot -Manifest $candidateFixture.manifest -Sealed $record -Ranges @() -TimedStart ([uint64]0x3fcab600) -AuxStart ([uint64]0x3fcac000) -DiagnosticStart ([uint64]0x3fcad800) -LegacyWords $legacy -FirstUsbFailure $firstFailure}
  Check ((ParentReplay $summary).expected_identity_bound) 'Parent independently replays immutable raw bytes and sealed source decoder'
  foreach($mutation in @('schema','required','read-count','read-sha','projection','source-hash','overlap')){
    $bad=$summary|ConvertTo-Json -Depth 25|ConvertFrom-Json
    switch($mutation){'schema'{$bad.schema='vc-lora-r19-runtime-stage-jtag-read-v9'};'required'{$bad.grant_reservation_required='true'};'read-count'{$bad.reads=@($bad.reads[0..18])};'read-sha'{$bad.reads[18].sha256='0'*64};'projection'{$bad.decoded.grant_reservation.state=1};'source-hash'{$candidateFixture.manifest.grant_reservation_diagnostics.decoder.sha256='0'*64};'overlap'{$record.symbols.grant_diagnostic.address='0x3fcadf00'}}
    Reject {ParentReplay $bad} ('Parent raw replay rejects '+$mutation)
    if($mutation-ceq'source-hash'){$candidateFixture.manifest.grant_reservation_diagnostics.decoder.sha256=Get-Sha256 $script:R19GrantReservationDecoderPath}
    if($mutation-ceq'overlap'){$record.symbols.grant_diagnostic.address='0x3fcadc00'}
  }
  $GrantReservationDiagnostics=$true;$GrantDiagnostics=$true;$ParamListDiagnostics=$true;$DiagnosticUsbFailureDiagnostics=$true;$AuxReadinessDiagnostics=$true;$timedPathEnabled=$true;$TimedPathMode='ExplicitHostArm'
  $manifestJson=$candidateFixture.manifest|ConvertTo-Json -Depth 30|ConvertFrom-Json
  Assert-CandidateDiagnosticAbiContract $manifestJson 'v10 fixture'
  Check $true 'Parent strict ABI accepts full v10 mode only'
  $GrantReservationDiagnostics=$false;Reject {Assert-CandidateDiagnosticAbiContract $manifestJson 'v10 fixture'} 'Parent refuses undeclared reservation mode'
}
Write-Output "check_r19_grant_reservation_artifact COMPLETE_PASS checks=$script:checks hardware_interaction=false"
& {
  $mockFixture=NewV10Fixture
  $mockArtifact=[pscustomobject]@{extended_records_enabled=$true;first_usb_failure_enabled=$true;timed_path_enabled=$true;aux_readiness_enabled=$true;diagnostic_usb_failure_enabled=$true;grant_diagnostics_enabled=$true;grant_reservation_enabled=$true}
  $names=@('runtime_stage','endpoint_fifo','hwcdc_restart','ground_usb_commit','first_usb_failure','timed_path','aux_readiness','diagnostic_usb_failure','grant_diagnostic','grant_reservation')
  foreach($name in $names){$mockArtifact|Add-Member NoteProperty ($name+'_address') $mockFixture[$name+'_address']}
  $mockRoot=Join-Path $fixtureRoot 'mock-capture-ten';[void][IO.Directory]::CreateDirectory($mockRoot)
  $ScriptsRoot=$mockRoot;$OpenOcdExecutable=$readerPath;$OpenOcdSha256=Get-Sha256 $readerPath
  $InterfaceConfig=$readerPath;$InterfaceConfigSha256=$OpenOcdSha256;$TargetConfig=$readerPath;$TargetConfigSha256=$OpenOcdSha256
  $ProbeSerial='mock-offline-only';$ProbeUsbLocation='1-1.1';$stageRecordBytes=68;$fifoRecordBytes=112
  function Invoke-NativeProcessCapture {
    param($Executable,$Arguments,$LogPath,$TimeoutMilliseconds)
    Check (@($Arguments|Where-Object{$_-ceq'halt'}).Count-eq1) 'Mock20-record capture has one SMP halt'
    $command=$Arguments-join"`n";$matches=[regex]::Matches($command,'dump_image \{([^}]+)\} (0x[0-9a-f]{8}) (\d+)')
    Check ($matches.Count-eq20) 'Actual reader builds exactly20 physical paired dumps'
    Check ($command.LastIndexOf('dump_image')-lt$command.IndexOf('catch { resume }')) 'All20 dumps precede unconditional SMP resume cleanup'
    for($ordinal=0;$ordinal-lt20;$ordinal++){
      $m=$matches[$ordinal];$name=$names[$ordinal%10];$sample=if($ordinal-lt10){'first'}else{'second'}
      $bytes=[Convert]::FromBase64String($mockFixture[$name+'_'+$sample+'_read_base64'])
      Check ([int]$m.Groups[3].Value-eq$bytes.Length-and$m.Groups[2].Value-ceq$mockFixture[$name+'_address']) ('Actual mock dump exact ABI '+$name+' '+$sample)
      [IO.File]::WriteAllBytes($m.Groups[1].Value,$bytes)
    }
    [IO.File]::WriteAllText($LogPath,(@('VC_LORA_JTAG_OPEN_SERIAL=mock-offline-only','VC_LORA_JTAG_OPEN_LOCATION=1-1.1','VC_LORA_JTAG_IDENTITY_MATCHED','VC_LORA_HALT_CPU0','VC_LORA_HALT_CURSTATE_CPU0=halted','VC_LORA_HALT_CURSTATE_CPU1=halted','VC_LORA_RESUME_CURSTATE_CPU0=running','VC_LORA_RESUME_CURSTATE_CPU1=running','shutdown command invoked')-join"`n"))
    [pscustomobject]@{exit_code=0;timed_out=$false;termination_proven=$true;launch_failure='';stdout_path='';stderr_path=''}
  }
  function Invoke-OpenOcdCleanup {[pscustomobject]@{required=$true;attempted=$true;exit_code=0;process_termination_proven=$true;resume_shutdown_proven=$true}}
  $raw=Read-LiveStageRecord -Artifact $mockArtifact -OutputDirectory $mockRoot -Attempt 1
  Check ($raw.smp_capture_proven-and$raw.cleanup.resume_shutdown_proven-and$raw.grant_reservation_first.Length-eq512-and$raw.grant_reservation_second.Length-eq512) 'New pair preserves both-CPU running/cleanup proof'
}
Import-Definitions 'tools/build_r19_candidate_artifacts.ps1' @('Add-OptionalUsbFailureMetadata','Add-DiagnosticAbiMetadata','Copy-CandidateRolePackage')
Import-Definitions 'tools/verify_r19_candidate_artifact.ps1' @('Assert-Condition','Assert-ModeContract','Assert-DiagnosticAbiContract')
& {
  $runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true;$TimedPathMode='ExplicitHostArm'
  $timedPathContract=Get-R19TimedPathCandidateContract $RepoRoot ExplicitHostArm;$auxReadinessContract=Get-R19AuxReadinessCandidateContract $RepoRoot $true
  $diagnosticUsbFailureContract=Get-R19DiagnosticUsbFailureCandidateContract $RepoRoot $true;$grantDiagnosticContract=Get-R19GrantDiagnosticCandidateContract $RepoRoot $true;$grantReservationContract=Get-R19GrantReservationCandidateContract $RepoRoot $true
  $usbRoleCapabilities=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode ExplicitHostArm -Enabled $true
  $metadata=[pscustomobject]@{runtime_fail_diagnostics_enabled=$true;acceptance_authorized=$false;acceptance_eligible=$false;deployment_authorized=$false};Add-DiagnosticAbiMetadata $metadata
  Assert-ModeContract $metadata fixture;Assert-DiagnosticAbiContract $metadata fixture
  Check ($metadata.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v10') 'Actual builder and verifier agree exact v10 metadata'
  $runRoot=Join-Path $fixtureRoot 'actual-builder-ten';[void][IO.Directory]::CreateDirectory($runRoot)
  foreach($role in $script:R19CandidateRoles){
    $stage=Copy-CandidateRolePackage $role
    foreach($header in @('r19_grant_reservation.hpp','r19_grant_reservation_record.hpp')){Check ((Get-Sha256 (Join-Path $stage ('high_speed/'+$header)))-ceq(Get-Sha256 (Join-Path $RepoRoot ('firmware/high_speed/'+$header)))) ('Builder byte-identical role header '+$role.role+' '+$header)}
  }
}
Write-Output "check_r19_grant_reservation_artifact ALL_PASS checks=$script:checks hardware_interaction=false"
Import-Definitions 'tools/invoke_r19_candidate_app_flash_hil.ps1' @('Assert-Condition','Read-PinnedFileUnderLock','Assert-CandidateModeRecord')
& {
  $runtimeFailDiagnosticsEnabled=$true;$acceptanceEligible=$false;$timedPathEnabled=$true;$auxReadinessEnabled=$true;$diagnosticUsbFailureEnabled=$true;$grantDiagnosticsEnabled=$true;$grantReservationEnabled=$true;$TimedPathMode='ExplicitHostArm'
  $c=NewV10Candidate 'flash-metadata-roundtrip'
  $m=$c.manifest|ConvertTo-Json -Depth 35|ConvertFrom-Json
  foreach($name in @('acceptance_eligible','acceptance_authorized','deployment_authorized')){$m|Add-Member NoteProperty $name $false}
  Assert-CandidateModeRecord $m 'manifest-v10';Check $true 'Actual flash contract accepts full detailed v10 candidate'
  $latest=$m|ConvertTo-Json -Depth 35|ConvertFrom-Json;$latest.schema='vc-lora-r19-candidate-artifact-latest-v1';$latest.PSObject.Properties.Remove('reader_schema')
  Assert-CandidateModeRecord $latest 'latest-v10';Check $true 'Actual latest pointer binds nested contracts without inventing top-level reader field'
  foreach($mutation in @('old-reader','missing-contract','producer','role-capabilities')){
    $bad=$m|ConvertTo-Json -Depth 35|ConvertFrom-Json
    switch($mutation){'old-reader'{$bad.reader_schema='vc-lora-r19-runtime-stage-jtag-read-v9'};'missing-contract'{$bad.PSObject.Properties.Remove('grant_reservation_diagnostics')};'producer'{$bad.grant_reservation_diagnostics.producer.kind='fake-plan'};'role-capabilities'{$bad.grant_reservation_diagnostics.producer.role_capabilities.vehicle=@('Prepare')}}
    Reject {Assert-CandidateModeRecord $bad 'bad-v10'} ('Actual flash mode rejects '+$mutation)
  }
}
Write-Output "check_r19_grant_reservation_artifact FROZEN_PASS checks=$script:checks hardware_interaction=false"
