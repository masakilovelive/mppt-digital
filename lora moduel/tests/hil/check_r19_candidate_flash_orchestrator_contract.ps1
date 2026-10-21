param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$testId = 'R19-CANDIDATE-APP-FLASH-ORCHESTRATOR-CONTRACT-001'
$repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$runnerPath = Join-Path $repo 'tools\invoke_r19_candidate_app_flash_hil.ps1'
$verifierPath = Join-Path $repo 'tools\verify_r19_candidate_artifact.ps1'
$commonPath = Join-Path $repo 'tools\r19_candidate_artifact_common.ps1'
$runbookPath = Join-Path $repo 'R19_CANDIDATE_FLASH_HIL_RUNBOOK.md'

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "$testId`: $Message" }
}

Assert-Contract (Test-Path -LiteralPath $runnerPath -PathType Leaf) `
    "missing dedicated R19 candidate flash orchestrator: $runnerPath"
Assert-Contract (Test-Path -LiteralPath $verifierPath -PathType Leaf) `
    "missing R19 candidate artifact verifier: $verifierPath"
Assert-Contract (Test-Path -LiteralPath $commonPath -PathType Leaf) `
    "missing R19 candidate artifact verifier common dependency: $commonPath"
Assert-Contract (Test-Path -LiteralPath $runbookPath -PathType Leaf) `
    "missing R19 candidate flash/HIL runbook: $runbookPath"

$text = Get-Content -LiteralPath $runnerPath -Raw
$verifierSha256 = (Get-FileHash -LiteralPath $verifierPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
$commonSha256 = (Get-FileHash -LiteralPath $commonPath -Algorithm SHA256).
    Hash.ToUpperInvariant()
foreach ($pattern in @(
    'vc-lora-r19-candidate-artifact-manifest-v1',
    'vc-lora-r19-candidate-artifact-latest-v1',
    'vc-lora-r19-candidate-artifact-handoff-v1',
    'vc-lora-r19-candidate-flash-evidence-v1',
    'R19-CANDIDATE-APP-FLASH-HIL-001',
    'PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY',
    'PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY',
    'R19_EXPERIMENTAL_HIL_ONE_RUN_NOT_DEPLOYMENT',
    'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT',
    'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED',
    '\[string\]\$OperatorSafetyAttestation',
    'one_run_hil_authorized',
    'runtime_fail_diagnostics_enabled',
    'acceptance_authorized',
    'deployment_authorized',
    'runs[\\/]candidates[\\/]R19-HS-PRODUCT-CANDIDATE-BUILD-001',
    'runs[\\/]candidates[\\/]R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001',
    'runs[\\/]validation[\\/]R19-CANDIDATE-APP-FLASH-HIL-001',
    'one immediate R19 runtime-fail diagnostic capture only',
    'Run one dual-COM read-only runtime-fail diagnostic capture, then mandatory accepted R18 rollback',
    'USB\\VID_303A&PID_1001&MI_00\\7&7131F6A&0&0000',
    'USB\\VID_303A&PID_1001\\90:70:69:11:81:A4',
    '90:70:69:11:81:a4',
    'USB\\VID_303A&PID_1001&MI_00\\7&2159A644&0&0000',
    'USB\\VID_303A&PID_1001\\1C:DB:D4:5A:83:80',
    '1c:db:d4:5a:83:80',
    '0x10000',
    'read-mac',
    'write-flash',
    'verify-flash',
    'vehicle_read_mac',
    'vehicle_write',
    'vehicle_verify',
    'vehicle_reenumeration',
    'ground_read_mac',
    'ground_write',
    'ground_verify',
    'ground_reenumeration',
    '9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52',
    '30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5',
    'R18-PRODUCTION-R4-ACCEPTED',
    'RollbackOnly',
    'MaxRollbackAttempts = 3',
    'Get-ProcessAncestorIds',
    'Select-CompetingClients',
    'Get-CompetingClients',
    'Write-CompetingClientGateEvidence',
    'competing_client_gate_',
    'final_seal\.json',
    'artifact_manifest\.json',
    'SHA256SUMS\.txt')) {
  Assert-Contract ($text -match $pattern) `
      "orchestrator lacks required contract pattern: $pattern"
}

Assert-Contract ($text -notmatch 'Invoke-Expression|\biex\b') `
    'orchestrator must never execute a constructed shell command string'
Assert-Contract ($text -notmatch 'erase-flash|bootloader\.bin|partitions\.bin|merged\.bin') `
    'candidate flash implementation contains a forbidden flash target/token'
Assert-Contract ($text -notmatch '(?m)-NotePropertyValue[ \t]*(?:\r?\n|$)') `
    'Add-Member NotePropertyValue must carry its argument in the same statement'
$verifierPinMatch = [regex]::Match($text,
    '(?s)\$expectedCandidateVerifierSha256\s*=\s*''([0-9A-F]{64})''')
$commonPinMatch = [regex]::Match($text,
    '(?s)\$expectedCandidateCommonSha256\s*=\s*''([0-9A-F]{64})''')
Assert-Contract ($verifierPinMatch.Success -and $commonPinMatch.Success -and
    [string]$verifierPinMatch.Groups[1].Value -ceq $verifierSha256 -and
    [string]$commonPinMatch.Groups[1].Value -ceq $commonSha256) `
    'candidate verifier and its common dependency are not exact-hash pinned'
Assert-Contract ($text -match
    '(?s)function\s+Read-PinnedFileUnderLock.*FileShare\]::Read.*ComputeHash.*ExpectedSha256' -and
    $text -match
    '(?s)function\s+Open-PinnedReadLock.*FileShare\]::Read.*ComputeHash.*ExpectedSha256') `
    'candidate verifier inputs are not hash-verified while held under read locks'
Assert-Contract ($text -match
    '(?s)function\s+Invoke-CandidateVerifier.*Read-PinnedFileUnderLock.*expectedCandidateVerifierSha256.*Read-PinnedFileUnderLock.*expectedCandidateCommonSha256.*Write-DurableBytes.*stagedVerifierPath.*Write-DurableBytes.*stagedCommonPath.*Open-PinnedReadLock.*stagedVerifierPath.*Open-PinnedReadLock.*stagedCommonPath.*&\s+\$stagedVerifierPath.*finally.*Dispose\(\)' -and
    $text -notmatch '&\s+\$verifier\b') `
    'candidate verifier is not executed from locked, exact staged verifier/common copies'
foreach ($modeRecord in @('latest','handoff','manifest','seal')) {
  Assert-Contract ($text -match
      ('Assert-CandidateModeRecord\s+\${0}\s+' -f $modeRecord)) `
      "orchestrator does not verify diagnostic mode on $modeRecord"
}

# Exercise the process classifier as a pure function with synthetic process
# rows.  A PowerShell ancestry chain that launches the canonical runtime-stage
# outer is trusted only for the explicit COM-token heuristic; known serial
# client names and unrelated processes must remain blocked.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $runnerPath, [ref]$tokens, [ref]$parseErrors)
Assert-Contract (@($parseErrors).Count -eq 0) `
    'candidate flash orchestrator does not parse cleanly'
foreach ($functionName in @(
    'Assert-Condition','Get-Sha256','Read-PinnedFileUnderLock',
    'Open-PinnedReadLock','Get-ProcessAncestorIds','Select-CompetingClients',
    'Write-CompetingClientGateEvidence','Assert-NoCompetingClients')) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
  }, $true))
  Assert-Contract ($definitions.Count -eq 1) `
      "expected one pure process-classifier function: $functionName"
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$pinFixture = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_candidate_verifier_pin_' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $pinFixture | Out-Null
  $lockedVerifierPath = Join-Path $pinFixture 'verify_r19_candidate_artifact.ps1'
  Copy-Item -LiteralPath $verifierPath -Destination $lockedVerifierPath
  $lockedVerifier = Read-PinnedFileUnderLock $lockedVerifierPath `
      $verifierSha256 'contract verifier'
  try {
    $mutationBlocked = $false
    try {
      Set-Content -LiteralPath $lockedVerifierPath -Value 'tampered' `
          -Encoding utf8 -ErrorAction Stop
    } catch {
      $mutationBlocked = $true
    }
    Assert-Contract ($mutationBlocked -and
        [string]$lockedVerifier.sha256 -ceq $verifierSha256 -and
        $lockedVerifier.bytes -is [byte[]]) `
        'source verifier pin/read lock did not reject concurrent mutation'
  } finally {
    $lockedVerifier.lock.Dispose()
  }

  $stagedCommonPath = Join-Path $pinFixture `
      'r19_candidate_artifact_common.ps1'
  Copy-Item -LiteralPath $commonPath -Destination $stagedCommonPath
  $stagedCommonLock = Open-PinnedReadLock $stagedCommonPath $commonSha256 `
      'contract staged common dependency'
  try {
    $mutationBlocked = $false
    try {
      Set-Content -LiteralPath $stagedCommonPath -Value 'tampered' `
          -Encoding utf8 -ErrorAction Stop
    } catch {
      $mutationBlocked = $true
    }
    Assert-Contract $mutationBlocked `
        'staged common-dependency read lock allowed concurrent mutation'
  } finally {
    $stagedCommonLock.Dispose()
  }

  $wrongPinAccepted = $false
  try {
    $wrongLock = Open-PinnedReadLock $stagedCommonPath ('0' * 64) `
        'contract wrong pin'
    $wrongPinAccepted = $true
    $wrongLock.Dispose()
  } catch {}
  Assert-Contract (-not $wrongPinAccepted) `
      'candidate verifier dependency accepted an incorrect exact hash pin'
} finally {
  if (Test-Path -LiteralPath $pinFixture) {
    Remove-Item -LiteralPath $pinFixture -Recurse -Force
  }
}

$syntheticProcesses = @(
  [pscustomobject]@{ProcessId=900;ParentProcessId=800;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_candidate_app_flash_hil.ps1'},
  [pscustomobject]@{ProcessId=800;ParentProcessId=700;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_runtime_stage_cause_experiment_hil.ps1 -VehicleProbeUsbLocation 1-3.4'},
  [pscustomobject]@{ProcessId=700;ParentProcessId=600;Name='pwsh.exe'
    ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe'
    CommandLine='pwsh -Command precheck COM3 COM6; invoke_r19_runtime_stage_cause_experiment_hil.ps1'},
  [pscustomobject]@{ProcessId=600;ParentProcessId=0;Name='codex-host.exe'
    ExecutablePath='C:\Program Files\Codex\codex-host.exe'
    CommandLine='codex-host'},
  [pscustomobject]@{ProcessId=500;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -Command monitor COM3'},
  [pscustomobject]@{ProcessId=400;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -Command invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM6'},
  [pscustomobject]@{ProcessId=350;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -Command monitor COM30 COM60'},
  [pscustomobject]@{ProcessId=300;ParentProcessId=0;Name='MissionPlanner.exe'
    ExecutablePath='C:\MissionPlanner\MissionPlanner.exe'
    CommandLine='MissionPlanner.exe'}
)
$classified = Select-CompetingClients -Processes $syntheticProcesses `
    -CurrentProcessId 900
$trustedIds = @($classified.trusted_launcher_ancestors |
    ForEach-Object {[int]$_.ProcessId})
$explicitIds = @($classified.explicit_com3_or_com6_refs |
    ForEach-Object {[int]$_.ProcessId})
$knownIds = @($classified.known_serial_clients |
    ForEach-Object {[int]$_.ProcessId})
Assert-Contract ($trustedIds.Count -eq 2 -and
    $trustedIds -contains 800 -and $trustedIds -contains 700 -and
    $explicitIds.Count -eq 2 -and
    $explicitIds -contains 500 -and $explicitIds -contains 400 -and
    $explicitIds -notcontains 800 -and $explicitIds -notcontains 700 -and
    $knownIds.Count -eq 1 -and $knownIds[0] -eq 300) `
    'process classifier did not narrowly trust only canonical outer ancestors'

$lookalikeChain = @(
  [pscustomobject]@{ProcessId=901;ParentProcessId=701;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_candidate_app_flash_hil.ps1'},
  [pscustomobject]@{ProcessId=701;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell evil_invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM3'}
)
$lookalikeClassified = Select-CompetingClients -Processes $lookalikeChain `
    -CurrentProcessId 901
Assert-Contract (@($lookalikeClassified.trusted_launcher_ancestors).Count -eq 0 -and
    @($lookalikeClassified.explicit_com3_or_com6_refs).Count -eq 1 -and
    [int]$lookalikeClassified.explicit_com3_or_com6_refs[0].ProcessId -eq 701) `
    'outer lookalike basename was incorrectly trusted'

$knownAncestorChain = @(
  [pscustomobject]@{ProcessId=902;ParentProcessId=302;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_candidate_app_flash_hil.ps1'},
  [pscustomobject]@{ProcessId=302;ParentProcessId=0;Name='python.exe'
    ExecutablePath='C:\Python\python.exe'
    CommandLine='python invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM6'}
)
$knownAncestorClassified = Select-CompetingClients `
    -Processes $knownAncestorChain -CurrentProcessId 902
Assert-Contract (@($knownAncestorClassified.trusted_launcher_ancestors).Count -eq 0 -and
    @($knownAncestorClassified.known_serial_clients).Count -eq 1 -and
    [int]$knownAncestorClassified.known_serial_clients[0].ProcessId -eq 302) `
    'known serial-client ancestor was incorrectly trusted'

$cycleChain = @(
  [pscustomobject]@{ProcessId=903;ParentProcessId=703;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_candidate_app_flash_hil.ps1'},
  [pscustomobject]@{ProcessId=703;ParentProcessId=903;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM3'}
)
$cycleIds = @(Get-ProcessAncestorIds -Processes $cycleChain `
    -StartProcessId 903)
$cycleClassified = Select-CompetingClients -Processes $cycleChain `
    -CurrentProcessId 903
Assert-Contract ($cycleIds.Count -eq 0 -and
    @($cycleClassified.trusted_launcher_ancestors).Count -eq 0 -and
    @($cycleClassified.explicit_com3_or_com6_refs).Count -eq 1 -and
    [int]$cycleClassified.explicit_com3_or_com6_refs[0].ProcessId -eq 703) `
    'cyclic process ancestry did not fail closed'

$duplicatePidInventory = @(
  [pscustomobject]@{ProcessId=904;ParentProcessId=704;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_candidate_app_flash_hil.ps1'},
  [pscustomobject]@{ProcessId=704;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM3'},
  [pscustomobject]@{ProcessId=704;ParentProcessId=0;Name='pwsh.exe'
    ExecutablePath='C:\Program Files\PowerShell\7\pwsh.exe'
    CommandLine='pwsh -File invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM3'}
)
$duplicateClassified = Select-CompetingClients `
    -Processes $duplicatePidInventory -CurrentProcessId 904
Assert-Contract (@($duplicateClassified.trusted_launcher_ancestors).Count -eq 0 -and
    @($duplicateClassified.explicit_com3_or_com6_refs).Count -eq 2) `
    'duplicate process IDs did not disable all launcher trust'

$missingCurrentInventory = @(
  [pscustomobject]@{ProcessId=705;ParentProcessId=0;Name='powershell.exe'
    ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    CommandLine='powershell -File invoke_r19_runtime_stage_cause_experiment_hil.ps1 COM6'}
)
$missingCurrentClassified = Select-CompetingClients `
    -Processes $missingCurrentInventory -CurrentProcessId 905
Assert-Contract (@($missingCurrentClassified.trusted_launcher_ancestors).Count -eq 0 -and
    @($missingCurrentClassified.explicit_com3_or_com6_refs).Count -eq 1) `
    'missing current process row did not disable all launcher trust'

# A competing-client failure must persist the exact blocking rows before the
# fail-closed assertion throws. This is diagnostic evidence only; it must not
# weaken or bypass either blocker.
$gateFixture = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_competing_gate_contract_' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $gateFixture -Force | Out-Null
  function Write-DurableJson([string]$LiteralPath, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 20
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($LiteralPath,[IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
  }
  function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
  }
  $script:syntheticCompetingClients = $classified
  function Get-CompetingClients { $script:syntheticCompetingClients }
  $evidence = $gateFixture
  $script:CompetingClientGateEvidenceSequence = 0
  $script:CompetingClientGateFailures = [Collections.ArrayList]::new()

  $cleanClients = [pscustomobject][ordered]@{
    captured_utc='2026-10-10T00:00:00.0000000Z'
    trusted_launcher_ancestors=@()
    known_serial_clients=@()
    explicit_com3_or_com6_refs=@()
  }
  $script:syntheticCompetingClients = $cleanClients
  Assert-NoCompetingClients | Out-Null
  Assert-NoCompetingClients | Out-Null
  Assert-Contract (@(Get-ChildItem -LiteralPath $gateFixture -File).Count -eq 0) `
      'clean repeated gates unexpectedly created failure evidence'

  $script:syntheticCompetingClients = $classified
  $gateRejectCount = 0
  1..2 | ForEach-Object {
    try { Assert-NoCompetingClients | Out-Null } catch { ++$gateRejectCount }
  }
  $gateFiles = @(Get-ChildItem -LiteralPath $gateFixture -File |
      Sort-Object Name)
  Assert-Contract ($gateRejectCount -eq 2 -and $gateFiles.Count -eq 2 -and
      $gateFiles[0].Name -ceq 'competing_client_gate_01.json' -and
      $gateFiles[1].Name -ceq 'competing_client_gate_02.json' -and
      $script:CompetingClientGateFailures.Count -eq 2 -and
      [string]$script:CompetingClientGateFailures[0].path -ceq
        'competing_client_gate_01.json' -and
      [string]$script:CompetingClientGateFailures[0].sha256 -match
        '^[0-9A-F]{64}$') `
      'repeated competing-client failures did not persist unique evidence'
  $gate = Get-Content -LiteralPath $gateFiles[0].FullName -Raw |
      ConvertFrom-Json
  Assert-Contract ([string]$gate.schema -ceq
        'vc-lora-r19-competing-client-gate-v1' -and
      [string]$gate.result -ceq 'FAIL' -and
      [string]$gate.status -ceq
        'FAIL_KNOWN_SERIAL_CLIENT_AND_EXPLICIT_COM_REFERENCE' -and
      [int]$gate.counts.known_serial_clients -eq 1 -and
      [int]$gate.counts.explicit_com3_or_com6_refs -eq 2 -and
      [int]$gate.known_serial_clients[0].ProcessId -eq 300 -and
      [int]$gate.explicit_com3_or_com6_refs[0].ProcessId -in @(500,400) -and
      [int]$gate.evidence_sequence -eq 1 -and
      -not [string]::IsNullOrWhiteSpace(
        [string]$gate.explicit_com3_or_com6_refs[0].CommandLine)) `
      'persisted competing-client evidence is incomplete or not exact'
} finally {
  if (Test-Path -LiteralPath $gateFixture) {
    Remove-Item -LiteralPath $gateFixture -Recurse -Force
  }
}

# The offline contract mode is deliberately executed from a copied wrapper in
# an isolated TEMP repository. It must not enumerate processes/devices, open a
# COM port, or invoke esptool. It exercises authorization, candidate binding,
# success sealing, partial-failure rollback accounting, and rollback failure.
$fixture = Join-Path ([IO.Path]::GetTempPath()) `
    ('vc_lora_r19_candidate_flash_contract_' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path (Join-Path $fixture 'tools') -Force |
      Out-Null
  Copy-Item -LiteralPath $runnerPath -Destination `
      (Join-Path $fixture 'tools\invoke_r19_candidate_app_flash_hil.ps1')

  foreach ($scenario in @('success','ground_write_failure','rollback_failure')) {
    $output = @()
    $failure = $null
    try {
      $output = @(& (Join-Path $fixture `
          'tools\invoke_r19_candidate_app_flash_hil.ps1') `
          -RepoRoot $fixture -OfflineContractTest `
          -OfflineScenario $scenario 2>&1)
    } catch {
      $failure = $_.Exception.Message
    }
    Assert-Contract ($null -eq $failure) `
        "offline contract scenario failed to execute: $scenario / $failure"
    $marker = ($output | Where-Object {
      [string]$_ -match '^R19-CANDIDATE-FLASH-OFFLINE-CONTRACT '
    } | Select-Object -Last 1)
    Assert-Contract ($null -ne $marker) `
        "offline contract scenario emitted no marker: $scenario"
    $recordPath = ([string]$marker -replace '^.*record=', '').Trim()
    Assert-Contract (Test-Path -LiteralPath $recordPath -PathType Leaf) `
        "offline contract record is missing: $scenario"
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $planPath = Join-Path (Split-Path -Parent $recordPath) `
        'offline_command_plan.json'
    Assert-Contract (Test-Path -LiteralPath $planPath -PathType Leaf) `
        "offline command plan is missing: $scenario"
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $commands = @($plan.commands)
    Assert-Contract ([bool]$plan.app_only -and
        [string]$plan.offset -ceq '0x10000' -and
        $commands.Count -eq 6) `
        "offline command plan policy/count mismatch: $scenario"
    $expectedKinds = @('read_mac','write','verify','read_mac','write','verify')
    $expectedPorts = @('COM3','COM3','COM3','COM6','COM6','COM6')
    for ($commandIndex = 0; $commandIndex -lt $commands.Count;
        ++$commandIndex) {
      $command = $commands[$commandIndex]
      [string[]]$argv = @($command.argv)
      Assert-Contract ([string]$command.kind -ceq
          $expectedKinds[$commandIndex] -and $argv[2] -ceq '--port' -and
          $argv[3] -ceq $expectedPorts[$commandIndex]) `
          "offline command role/kind mismatch: $scenario/$commandIndex"
      Assert-Contract (@($argv | Where-Object {
        $_ -match '(?i)erase|bootloader|partitions?|merged|boot_app0'
      }).Count -eq 0) `
          "offline command contains a forbidden token: $scenario/$commandIndex"
      if ([string]$command.kind -in @('write','verify')) {
        Assert-Contract (@($argv | Where-Object {
          $_ -ceq '0x10000' }).Count -eq 1 -and
          @($argv | Where-Object {
            $_.EndsWith('.bin',[StringComparison]::OrdinalIgnoreCase)
          }).Count -eq 1) `
          "offline app command is not exact: $scenario/$commandIndex"
      }
    }
    Assert-Contract ([string]$record.schema -ceq `
        'vc-lora-r19-candidate-flash-evidence-v1') `
        "offline record schema mismatch: $scenario"
    Assert-Contract ($record.runtime_fail_diagnostics_enabled -is [bool] -and
        -not [bool]$record.runtime_fail_diagnostics_enabled -and
        [bool]$record.acceptance_eligible -and
        $record.acceptance_authorized -is [bool] -and
        -not [bool]$record.acceptance_authorized -and
        [string]$record.authorization.scope -ceq
          'one immediate R19 physical acceptance run only') `
        "normal offline mode/authorization binding mismatch: $scenario"
    Assert-Contract (-not [bool]$record.external_actions.device_access_attempted `
        -and -not [bool]$record.external_actions.process_inventory_queried `
        -and -not [bool]$record.external_actions.esptool_executed `
        -and -not [bool]$record.external_actions.firmware_write_attempted) `
        "offline scenario reached an external action: $scenario"
    if ($scenario -ceq 'success') {
      Assert-Contract ([string]$record.result -ceq 'PASS' -and
          [string]$record.status -ceq `
            'PASS_OFFLINE_CONTRACT_NO_HARDWARE' -and
          [bool]$record.one_run_hil_authorized -and
          -not [bool]$record.deployment_authorized) `
          'offline success authorization semantics are wrong'
    } elseif ($scenario -ceq 'ground_write_failure') {
      Assert-Contract ([string]$record.result -ceq 'PASS' -and
          [string]$record.rollback.result -ceq 'PASS' -and
          [bool]$record.rollback.required) `
          'partial-failure scenario did not prove automatic R18 rollback'
    } else {
      Assert-Contract ([string]$record.result -ceq 'PASS' -and
          [string]$record.simulated_terminal_status -ceq `
            'FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED') `
          'rollback-failure scenario did not fail closed'
    }
    $flashSeal = Get-Content -LiteralPath (Join-Path `
        (Split-Path -Parent $recordPath) 'final_seal.json') -Raw |
      ConvertFrom-Json
    Assert-Contract ($flashSeal.runtime_fail_diagnostics_enabled -is [bool] -and
        -not [bool]$flashSeal.runtime_fail_diagnostics_enabled -and
        [bool]$flashSeal.acceptance_eligible -and
        $flashSeal.acceptance_authorized -is [bool] -and
        -not [bool]$flashSeal.acceptance_authorized) `
        "normal flash seal mode binding mismatch: $scenario"
  }

  $diagnosticOutput = @(& (Join-Path $fixture `
      'tools\invoke_r19_candidate_app_flash_hil.ps1') `
      -RepoRoot $fixture -OfflineContractTest -OfflineScenario success `
      -RuntimeFailDiagnostics 2>&1)
  $diagnosticMarker = ($diagnosticOutput | Where-Object {
    [string]$_ -match '^R19-CANDIDATE-FLASH-OFFLINE-CONTRACT '
  } | Select-Object -Last 1)
  Assert-Contract ($null -ne $diagnosticMarker) `
      'diagnostic offline contract emitted no marker'
  $diagnosticRecordPath = ([string]$diagnosticMarker -replace
      '^.*record=', '').Trim()
  $diagnosticRecord = Get-Content -LiteralPath $diagnosticRecordPath -Raw |
    ConvertFrom-Json
  $diagnosticSeal = Get-Content -LiteralPath (Join-Path `
      (Split-Path -Parent $diagnosticRecordPath) 'final_seal.json') -Raw |
    ConvertFrom-Json
  Assert-Contract ([bool]$diagnosticRecord.runtime_fail_diagnostics_enabled -and
      -not [bool]$diagnosticRecord.acceptance_authorized -and
      -not [bool]$diagnosticRecord.deployment_authorized -and
      [string]$diagnosticRecord.hil_authorization_token -ceq
        'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT' -and
      [string]$diagnosticRecord.authorization.scope -ceq
        'one immediate R19 runtime-fail diagnostic capture only' -and
      [string]$diagnosticRecord.next_required_action -ceq
        'Run one dual-COM read-only runtime-fail diagnostic capture, then mandatory accepted R18 rollback') `
      'diagnostic flash record safety semantics are wrong'
  Assert-Contract ([bool]$diagnosticSeal.runtime_fail_diagnostics_enabled -and
      -not [bool]$diagnosticSeal.acceptance_authorized -and
      -not [bool]$diagnosticSeal.deployment_authorized -and
      [string]$diagnosticSeal.hil_authorization_token -ceq
        'R19_RUNTIME_FAIL_DIAGNOSTIC_HIL_ONE_RUN_NOT_ACCEPTANCE_NOT_DEPLOYMENT' -and
      [string]$diagnosticSeal.authorization_scope -ceq
        'one immediate R19 runtime-fail diagnostic capture only' -and
      [string]$diagnosticSeal.next_required_action -ceq
        'Run one dual-COM read-only runtime-fail diagnostic capture, then mandatory accepted R18 rollback') `
      'diagnostic flash final seal safety semantics are wrong'

  $unsafeAccepted = $false
  try {
    & (Join-Path $fixture `
        'tools\invoke_r19_candidate_app_flash_hil.ps1') `
        -RepoRoot $fixture -OfflineContractTest -OfflineScenario success `
        -OperatorSafetyAttestation `
          'PIXHAWK_DISARMED_PROPULSION_ISOLATED_ANTENNAS_CONNECTED_GND_3V3_CHECKED_PARAM_BACKUP_SAVED' `
        2>&1 | Out-Null
    $unsafeAccepted = $true
  } catch {}
  Assert-Contract (-not $unsafeAccepted) `
      'offline mode accepted a live physical safety attestation'

  Write-Output "$testId PASS"
} finally {
  $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($fixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fixture) -match
        '^vc_lora_r19_candidate_flash_contract_[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fixture)) {
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}
