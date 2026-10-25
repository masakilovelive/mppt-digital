[CmdletBinding()]
param(
  [string]$RepoRoot='',
  [string]$SourceCandidateRoot='',
  [string]$BrokenVerifierPath='',
  [string]$OutputDirectory=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not$RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$validation=Join-Path $repo 'runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix'
if(-not$SourceCandidateRoot){$SourceCandidateRoot=Join-Path $repo 'runs/candidates/R19-GRANT-RESERVATION-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/20261024T214240351Z-b02ed633'}
if(-not$BrokenVerifierPath){$BrokenVerifierPath=Join-Path $validation 'verify_r19_candidate_artifact.pre-reservation-compile-fix.ps1'}
if(-not$OutputDirectory){$OutputDirectory=Join-Path $validation ('builder-output-main-replay-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$source=(Resolve-Path -LiteralPath $SourceCandidateRoot).Path
$golden=(Resolve-Path -LiteralPath $BrokenVerifierPath).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Use a fresh offline replay output directory'}
[void][IO.Directory]::CreateDirectory($out)
$script:checks=0
function Check([bool]$Value,[string]$Name){$script:checks++;if(-not$Value){throw ('FAIL '+$Name)}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function SaveJson([string]$Path,[object]$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 50)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))}
function SourceInventory {
  @(Get-ChildItem -LiteralPath $source -Recurse -File|Sort-Object FullName|ForEach-Object{[pscustomobject]@{path=$_.FullName.Substring($source.Length+1).Replace('\','/');size_bytes=$_.Length;sha256=Hash $_.FullName}})
}
function ImportFixtureFunctions([string]$Relative,[string[]]$Names){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Relative),[ref]$tokens,[ref]$errors)
  Check (@($errors).Count-eq0) ('Parse fixture helpers '+$Relative)
  foreach($name in $Names){
    $nodes=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name})
    Check ($nodes.Count-eq1) ('Unique fixture helper '+$name)
    . ([scriptblock]::Create($nodes[0].Extent.Text))
    Set-Item -Path ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock
  }
}

# Boundary: this replays real builder output through the complete verifier main.
# It does not invoke a builder, compiler, native tool, device, PnP or process scan.
# Real compiler binaries/ELF/MAP and source payloads retain their original bytes.
# Only copied fixture JSON paths and dependent hashes/seals are rebased below.
$before=SourceInventory
SaveJson (Join-Path $out 'original_candidate_inventory_before.json') $before
Check ((Hash $golden)-ceq'DEF19B28F8EFF54814DB14BB6A9D9583A8424BFC1DA7085D9E7A2D21C7264DA3') 'Golden broken verifier is the exact observed source'
$manifestOriginal=Get-Content -LiteralPath (Join-Path $source 'candidate_manifest.json') -Raw|ConvertFrom-Json
Check ($manifestOriginal.grant_reservation_diagnostics.enabled-is[bool]-and$manifestOriginal.grant_reservation_diagnostics.enabled-and$manifestOriginal.reader_schema-ceq'vc-lora-r19-runtime-stage-jtag-read-v10') 'Actual builder output selects reservation v10'
Check (@($manifestOriginal.roles).Count-eq2-and$manifestOriginal.roles[0].role-ceq'vehicle'-and$manifestOriginal.roles[1].role-ceq'ground') 'Actual builder output preserves serial Vehicle then Ground'
foreach($role in $manifestOriginal.roles){Check ($role.compile.argv-contains$manifestOriginal.candidate_enable.property-and@($role.runtime_diagnostic_symbols.symbols.PSObject.Properties).Count-eq10) ('Actual builder '+$role.role+' flags and ten symbols')}

$fixtureRepo=Join-Path $out 'isolated-repository'
[void][IO.Directory]::CreateDirectory($fixtureRepo)
foreach($record in $manifestOriginal.canonical_source_snapshot.files){
  $original=Join-Path $repo $record.path
  Check ((Hash $original)-ceq$record.sha256) ('Exact builder source '+$record.path)
  $destination=Join-Path $fixtureRepo $record.path
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
  Copy-Item -LiteralPath $original -Destination $destination
}
$fixtureTools=Join-Path $fixtureRepo 'tools'
Copy-Item -LiteralPath (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1') -Destination (Join-Path $fixtureTools 'r19_candidate_artifact_common.ps1')
$fixtureRoot=Join-Path $fixtureRepo $manifestOriginal.artifact_root
[void][IO.Directory]::CreateDirectory($fixtureRoot)
foreach($entry in Get-ChildItem -LiteralPath $source -Force){
  if($entry.Name-ceq'BUILD_FAILED.txt'){continue}
  Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $fixtureRoot $entry.Name) -Recurse
}
Check (-not(Test-Path -LiteralPath (Join-Path $fixtureRoot 'BUILD_FAILED.txt'))) 'Only failed-build marker excluded from isolated artifact root'

# Existing artifact-builder fixture utilities maintain the whole manifest,
# inventory, SHA256SUMS, final seal and handoff hash dependency chain.
ImportFixtureFunctions 'tests/arduino_compile/check_r19_candidate_artifact_builder_contract.ps1' @('Write-FixtureText','Get-TestSha256','Write-TestJson','Write-TestHashSidecar','Update-FixtureArtifactHashes')
$manifestPath=Join-Path $fixtureRoot 'candidate_manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$canonicalHeader=Join-Path $fixtureRepo 'third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h'
$installedCore=Join-Path $fixtureRepo 'fixture-installed-core'
$installedHeader=Join-Path $installedCore 'cores/esp32/HWCDCR19Diagnostic.h'
foreach($path in @($canonicalHeader,$installedHeader)){
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
  Copy-Item -LiteralPath (Join-Path $repo 'third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h') -Destination $path
  Check ((Hash $path)-ceq$manifest.toolchain.hwcdc.canonical_diagnostic_h_sha256) 'Fixture header retains compiled input bytes'
}
$manifest.toolchain.esp32_core.installed_root=$installedCore
$manifest.toolchain.hwcdc.installed_diagnostic_h_path=$installedHeader
$manifest.toolchain.hwcdc.canonical_diagnostic_h_path=$canonicalHeader
$semanticPath=Join-Path $fixtureRoot $manifest.hwcdc_semantic_contract.summary.path
$semantic=Get-Content -LiteralPath $semanticPath -Raw|ConvertFrom-Json
$semantic.diagnostic_header_path=$installedHeader
$semantic.canonical_diagnostic_header_path=$canonicalHeader
SaveJson $semanticPath $semantic
$manifest.hwcdc_semantic_contract.summary.sha256=Hash $semanticPath
$manifest.hwcdc_semantic_contract.summary.size_bytes=(Get-Item -LiteralPath $semanticPath).Length
SaveJson $manifestPath $manifest
Update-FixtureArtifactHashes $fixtureRoot
$sealPath=Join-Path $fixtureRoot 'final_seal.json'
$seal=Get-Content -LiteralPath $sealPath -Raw|ConvertFrom-Json
$seal.hwcdc_semantic_summary_sha256=Hash $semanticPath
SaveJson $sealPath $seal
Write-TestHashSidecar (Join-Path $fixtureRoot 'final_seal.sha256') 'final_seal.json' $sealPath
$handoffPath=Join-Path $fixtureRoot 'handoff.json'
$handoff=Get-Content -LiteralPath $handoffPath -Raw|ConvertFrom-Json
$handoff.final_seal.sha256=Hash $sealPath
SaveJson $handoffPath $handoff
Write-TestHashSidecar (Join-Path $fixtureRoot 'handoff.sha256') 'handoff.json' $handoffPath

$fixtureVerifier=Join-Path $fixtureTools 'verify_r19_candidate_artifact.ps1'
$mode=@{RepoRoot=$fixtureRepo;ArtifactRoot=$fixtureRoot;RuntimeFailDiagnostics=$true;TimedPathMode='ExplicitHostArm';AuxReadinessDiagnostics=$true;DiagnosticUsbFailureDiagnostics=$true;GrantDiagnostics=$true;GrantReservationDiagnostics=$true}
function InvokeMain([string]$Name,[string]$Verifier,[bool]$ExpectedPass,[string]$ExpectedError=''){
  Copy-Item -LiteralPath $Verifier -Destination $fixtureVerifier -Force
  $output=@();$errorText='';$ok=$false
  try{$output=@(& $fixtureVerifier @mode);$ok=@($output|Where-Object{$_-like'FW-R19-CANDIDATE-ARTIFACT-VERIFY-001 PASS*'}).Count-eq1}catch{$errorText=$_.Exception.Message}
  [IO.File]::WriteAllLines((Join-Path $out ($Name+'.log')),[string[]]@($output+$errorText),[Text.UTF8Encoding]::new($false))
  Check ($ok-eq$ExpectedPass-and(-not$ExpectedError-or$errorText-like('*'+$ExpectedError+'*'))) ('Whole verifier main '+$Name+' '+$errorText)
  return [pscustomobject]@{case=$Name;passed=$ok;expected_pass=$ExpectedPass;error=$errorText;verifier_sha256=Hash $fixtureVerifier;hardware_interaction=$false}
}
$cases=[Collections.Generic.List[object]]::new()
$cases.Add((InvokeMain 'RED_observed_missing_reservation_enable' $golden $false 'Candidate enable provenance is invalid'))
$currentVerifier=Join-Path $repo 'tools/verify_r19_candidate_artifact.ps1'
$cases.Add((InvokeMain 'GREEN_current_whole_main' $currentVerifier $true))

# A missing macro remains a rejection even when all copied fixture hashes and
# seals are internally coherent. The compiler flag is not inferred from v10.
$goodManifest=[IO.File]::ReadAllBytes($manifestPath)
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$manifest.candidate_enable.property=$manifest.candidate_enable.property.Replace(' -DVC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS=1','')
SaveJson $manifestPath $manifest
Update-FixtureArtifactHashes $fixtureRoot
$cases.Add((InvokeMain 'NEGATIVE_resealed_missing_macro' $currentVerifier $false 'Candidate enable provenance is invalid'))
[IO.File]::WriteAllBytes($manifestPath,$goodManifest)
Update-FixtureArtifactHashes $fixtureRoot
$cases.Add((InvokeMain 'GREEN_restored_exact_macro' $currentVerifier $true))
$after=SourceInventory
SaveJson (Join-Path $out 'original_candidate_inventory_after.json') $after
Check (($before|ConvertTo-Json -Depth 5 -Compress)-ceq($after|ConvertTo-Json -Depth 5 -Compress)) 'Original failed candidate179file inventory unchanged'
$summary=[pscustomobject]@{schema='vc-lora-r19-reservation-builder-output-main-replay-v1';result='PASS';checks=$script:checks;boundary='ACTUAL_BUILDER_OUTPUT_TO_WHOLE_VERIFIER_MAIN_ONLY';builder_executed=$false;compiler_executed=$false;native_tool_executed=$false;hardware_interaction=$false;source_candidate_root=$source;source_candidate_unchanged=$true;source_candidate_files=$before.Count;fixture_artifact_root=$fixtureRoot;compiler_payload_bytes_preserved=$true;fixture_metadata_rebased_and_resealed=$true;cases=$cases.ToArray();acceptance_authorized=$false;deployment_authorized=$false}
SaveJson (Join-Path $out 'summary.json') $summary
Write-Output ('R19_GRANT_RESERVATION_BUILDER_OUTPUT_MAIN_REPLAY PASS checks='+$script:checks+' hardware_interaction=false builder_executed=false output='+$out)
