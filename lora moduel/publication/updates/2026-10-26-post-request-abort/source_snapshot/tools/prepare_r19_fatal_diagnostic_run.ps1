[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CandidateId,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [string]$RepoRoot=(Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $repo 'tools/r19_timed_path_outer.ps1')
. (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1')
function NeedPrepared([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Get-R19FatalPreparedOutputPath {
  param([string]$OutputDirectory)
  $driveAbsolute=$OutputDirectory-cmatch'^[A-Za-z]:[\\/]'
  $uncAbsolute=$OutputDirectory-cmatch'^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)'
  if([string]::IsNullOrWhiteSpace($OutputDirectory)-or-not($driveAbsolute-or$uncAbsolute)){throw 'Preparation output directory must be explicit and absolute'}
  $directory=[IO.Path]::GetFullPath($OutputDirectory)
  if([IO.File]::Exists($directory)){throw 'Preparation output directory is an existing file'}
  $path=Join-Path $directory 'prepared_fatal_explicit_host_arm.json'
  if(Test-Path -LiteralPath $path){throw 'Do not overwrite an existing prepared run'}
  return $path
}
$out=Get-R19FatalPreparedOutputPath -OutputDirectory $OutputDirectory
NeedPrepared ($CandidateId-cmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$') 'Unsafe explicit candidate identity'
$selection=@{
  AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true
  ParamListDiagnostics=$true;GrantDiagnostics=$true
  GrantReservationDiagnostics=$true;GrantReservationStopDiagnostics=$true
  GrantAgreementDiagnostics=$true;GrantReservationFatalDiagnostics=$true
}
$leaf=Get-R19CandidateOutputLeaf $true 'ExplicitHostArm' $true $true $true $true $true $true $true
NeedPrepared ($leaf-ceq'R19-GRANT-FATAL-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001') 'Fatal mode has no independent namespace'
$relative='runs/candidates/'+$leaf+'/latest.json'
$latestPath=Join-Path $repo $relative
$latestHash=Get-R19Sha256 $latestPath
$latest=Get-Content -LiteralPath $latestPath -Raw|ConvertFrom-Json
NeedPrepared ($latest.schema-ceq'vc-lora-r19-candidate-artifact-latest-v1'-and$latest.result-ceq'PASS'-and$latest.artifact_id-ceq$CandidateId) 'Latest does not select the reviewed successful candidate'
$expectedArtifact='runs/candidates/'+$leaf+'/'+$CandidateId
NeedPrepared ($latest.artifact_root-ceq$expectedArtifact) 'Fatal artifact escaped the reviewed namespace'
$artifact=Join-Path $repo $expectedArtifact
$documents=[ordered]@{latest=$latest}
foreach($spec in @(@('candidate_manifest','candidate_manifest.json'),@('handoff','handoff.json'),@('final_seal','final_seal.json'))){
  $binding=$latest.($spec[0])
  NeedPrepared ($binding.path-ceq($expectedArtifact+'/'+$spec[1])-and$binding.sha256-cmatch'^[0-9A-F]{64}$') 'Sealed candidate binding path or digest differs'
  $path=Join-Path $repo $binding.path
  NeedPrepared ((Get-R19Sha256 $path)-ceq$binding.sha256) 'Sealed document SHA differs'
  $document=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  NeedPrepared ($document.artifact_id-ceq$CandidateId) 'Sealed candidate identity differs'
  $documents[$spec[0]]=$document
}
$manifest=$documents.candidate_manifest
foreach($name in $documents.Keys){
  $document=$documents[$name]
  foreach($field in @('acceptance_eligible','acceptance_authorized','deployment_authorized')){NeedPrepared ($document.$field-is[bool]-and-not$document.$field) 'Prepared diagnostic artifacts cannot grant acceptance or deployment'}
  NeedPrepared ($document.runtime_fail_diagnostics_enabled-is[bool]-and$document.runtime_fail_diagnostics_enabled) 'Runtime-failure diagnostics are mandatory'
  [void](Assert-R19GrantReservationCandidateContract -Value $document.grant_reservation_diagnostics -RepoRoot $repo -Enabled $true -CancellationEnabled $true -AgreementEnabled $true -FatalEnabled $true)
  [void](Assert-R19GrantReservationStopCandidateContract -Value $document.grant_reservation_stop_diagnostics -RepoRoot $repo -Enabled $true -AgreementEnabled $true -FatalEnabled $true)
  [void](Assert-R19GrantAgreementCandidateContract -Value $document.grant_agreement_diagnostics -RepoRoot $repo -Enabled $true -FatalEnabled $true)
  [void](Assert-R19GrantReservationFatalCandidateContract -Value $document.grant_reservation_fatal_diagnostics -RepoRoot $repo -Enabled $true)
  NeedPrepared ($document.grant_reservation_fatal_diagnostics.paired_raw_reads-eq24) 'Fatal mode requires24 paired raw reads per role'
  if($name-cne'latest'){NeedPrepared ($document.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v12') 'Fatal artifact reader-v12 is mandatory'}
}
NeedPrepared ((@($manifest.compile_order)-join',')-ceq'vehicle,ground') 'Candidate compile order differs'
NeedPrepared ($manifest.flash_policy.app_only-is[bool]-and$manifest.flash_policy.app_only-and$manifest.flash_policy.offset-ceq'0x10000'-and(@($manifest.flash_policy.upload_order)-join',')-ceq'vehicle,ground') 'Candidate must remain application-only Vehicle then Ground'
NeedPrepared (@($manifest.roles).Count-eq2) 'Exactly two unique compiled roles required'
$addresses=@{}
foreach($roleName in @('vehicle','ground')){
  $rows=@($manifest.roles|Where-Object{$_.role-ceq$roleName})
  NeedPrepared ($rows.Count-eq1) 'Missing or duplicate compiled role'
  $role=$rows[0]
  $elfRows=@($role.reproducibility_artifacts.files|Where-Object{$_.path-ceq('evidence/build/'+$roleName+'/application.elf')})
  $mapRows=@($role.reproducibility_artifacts.files|Where-Object{$_.path-ceq('evidence/build/'+$roleName+'/application.map')})
  NeedPrepared ($elfRows.Count-eq1-and$mapRows.Count-eq1) 'Unique reproducible ELF and map are required'
  $elf=Join-Path $artifact $elfRows[0].path
  $map=Join-Path $artifact $mapRows[0].path
  NeedPrepared ((Get-R19Sha256 $elf)-ceq$elfRows[0].sha256-and(Get-R19Sha256 $map)-ceq$mapRows[0].sha256) 'Reproducible role symbol files differ'
  NeedPrepared ($role.application.path-ceq('firmware/'+$roleName+'.application.bin')) 'Role application path differs'
  NeedPrepared ((Get-R19Sha256 (Join-Path $artifact $role.application.path))-ceq$role.application.sha256) 'Role application SHA differs'
  $actual=Get-R19DiagnosticSymbolBinding $elf $map $role.application.sha256 $true $true $true $true $true $true $true $true $true
  Assert-R19GrantReservationShape $role.runtime_diagnostic_symbols ($actual|ConvertTo-Json -Depth 20|ConvertFrom-Json) ('prepared-symbols.'+$roleName)
  NeedPrepared (@($actual.symbols.PSObject.Properties).Count-eq13) 'Fatal reader requires exactly13 ELF symbols, not13 RAM records'
  NeedPrepared ($actual.symbols.grant_reservation_fatal.name-ceq'vc_lora_r19_grant_reservation_fatal_record'-and$actual.symbols.grant_reservation_fatal.size_bytes-eq128) 'Independent Fatal128 symbol differs'
  NeedPrepared ($actual.symbols.grant_reservation.size_bytes-eq512-and$actual.symbols.grant_reservation_stop.size_bytes-eq128-and$actual.symbols.grant_agreement_capability.size_bytes-eq4) 'Original reservation512/STOP128/capability4 ABIs changed'
  $addresses[$roleName]=$actual.symbols.runtime_stage.address
}
$toolPaths=@(Get-R19TimedPathOuterToolPaths @selection)
NeedPrepared (@($toolPaths|Where-Object{$_-ceq'tools/read_r19_grant_reservation_fatal_record.ps1'}).Count-eq1) 'Prepared tool closure must explicitly include the fatal decoder'
$tools=@($toolPaths|ForEach-Object{[pscustomobject][ordered]@{path=$_;sha256=Get-R19Sha256 (Join-Path $repo $_)}})
$pin=[pscustomobject][ordered]@{
  schema='vc-lora-r19-timed-path-prepared-run-v1';mode='ExplicitHostArm';candidate_id=$CandidateId
  latest_sha256=$latestHash;latest_path=$relative
  capture_seconds=40;product_budget_ms=106
  acceptance_authorized=$false;deployment_authorized=$false;live_authorization_granted=$false
  vehicle_runtime_stage_address=$addresses.vehicle;ground_runtime_stage_address=$addresses.ground
  aux_readiness_diagnostics=$true;diagnostic_usb_failure_diagnostics=$true;usb_role_capabilities=$manifest.usb_role_capabilities
  read_comparison_mode='None';param_list_diagnostics=$true;grant_diagnostics=$true;grant_reservation_diagnostics=$true
  reservation_prepare_seconds=15;grant_reservation_contract=$manifest.grant_reservation_diagnostics
  grant_reservation_stop_diagnostics=$true;grant_reservation_stop_contract=$manifest.grant_reservation_stop_diagnostics
  grant_agreement_diagnostics=$true;grant_agreement_contract=$manifest.grant_agreement_diagnostics
  grant_reservation_fatal_diagnostics=$true;grant_reservation_fatal_contract=$manifest.grant_reservation_fatal_diagnostics
  tools=$tools
}
[void](Assert-R19TimedPathPreparedContract -Pin $pin -Mode ExplicitHostArm @selection -RepoRoot $repo)
NeedPrepared ((Get-R19Sha256 $latestPath)-ceq$latestHash) 'Latest changed during preparation; rebuild the independently reviewed selection'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $out))
$stream=[IO.FileStream]::new($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($pin|ConvertTo-Json -Depth 35));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
Write-Output ('PREPARED_ONLY candidate='+$CandidateId+' tools='+$tools.Count+' symbols_per_role=13 paired_raw_reads_per_role=24 sha256='+(Get-R19Sha256 $out))
