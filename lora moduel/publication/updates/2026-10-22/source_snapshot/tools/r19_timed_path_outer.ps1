# Pure contracts for the opt-in timed-path orchestration. No device access on import.
function Get-R19TimedPathOuterToolPaths {
  @('tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1',
    'tools/invoke_r19_candidate_app_flash_hil.ps1',
    'tools/read_r19_runtime_stage_jtag.ps1','tools/invoke_r19_jtag_preflash_gate.ps1',
    'tools/run_r19_timed_path_capture.ps1','tools/r19_timed_path_acquisition.ps1',
    'tools/r19_timed_path_outer.ps1','tools/read_r19_timed_path_record.ps1',
    'tools/read_r19_first_usb_failure_record.ps1','tools/r19_host_readiness_wire.ps1',
    'tools/r19_host_readiness_workflow.ps1','tools/r19_usb_clock_correlation.ps1',
    'tools/r19_timed_path_trace.ps1','tools/r19_startup_reader.cs',
    'tools/r19_continuous_reader.cs','tools/r19_candidate_artifact_common.ps1',
    'tools/verify_r19_candidate_artifact.ps1')
}

function Assert-R19TimedPathPreparedContract {
  param([object]$Pin,[ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode)
  function NeedPin($Value,$Message){if(-not$Value){throw $Message}}
  NeedPin ($null-ne$Pin) 'Prepared pin is missing'
  foreach($name in @('schema','mode','candidate_id','latest_sha256','latest_path',
      'capture_seconds','product_budget_ms','acceptance_authorized',
      'deployment_authorized','live_authorization_granted',
      'vehicle_runtime_stage_address','ground_runtime_stage_address','tools')){
    NeedPin ($null-ne$Pin.PSObject.Properties[$name]) "Prepared pin lacks $name"
  }
  NeedPin ($Pin.schema-ceq'vc-lora-r19-timed-path-prepared-run-v1'-and
    $Pin.mode-ceq$Mode) 'Prepared pin schema or mode differs'
  NeedPin ($Pin.candidate_id-is[string]-and$Pin.candidate_id-cmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$') 'Unsafe candidate id'
  NeedPin ($Pin.latest_sha256-is[string]-and$Pin.latest_sha256-cmatch'^[0-9A-F]{64}$') 'Invalid latest digest'
  $leaf=if($Mode-ceq'SyncOnly'){'SYNC-ONLY'}else{'EXPLICIT-HOST-ARM'}
  NeedPin ($Pin.latest_path-ceq("runs/candidates/R19-TIMED-PATH-$leaf-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json")) 'Prepared latest path differs from mode'
  NeedPin (($Pin.capture_seconds-is[int]-or$Pin.capture_seconds-is[long])-and$Pin.capture_seconds-eq40-and
    ($Pin.product_budget_ms-is[int]-or$Pin.product_budget_ms-is[long])-and$Pin.product_budget_ms-eq106) 'Prepared durations differ'
  foreach($name in @('acceptance_authorized','deployment_authorized','live_authorization_granted')){
    NeedPin ($Pin.$name-is[bool]-and-not$Pin.$name) 'Preparation never grants live or product authorization'
  }
  $addresses=@()
  foreach($name in @('vehicle_runtime_stage_address','ground_runtime_stage_address')){
    NeedPin ($Pin.$name-is[string]-and$Pin.$name-cmatch'^0x3fc[89abcd][0-9a-f]{4}$') 'Invalid prepared stage address'
    $address=[Convert]::ToUInt32($Pin.$name.Substring(2),16)
    NeedPin (($address%4)-eq0) 'Unaligned prepared stage address'
    $addresses+=,$address
  }
  NeedPin ($addresses[0]-ne$addresses[1]) 'Prepared stage addresses must differ'
  $expected=@(Get-R19TimedPathOuterToolPaths)
  NeedPin ($Pin.tools-is[array]-and$Pin.tools.Count-eq$expected.Count) 'Prepared tool count differs'
  foreach($path in $expected){
    $matches=@($Pin.tools|Where-Object{$_.path-ceq$path})
    NeedPin ($matches.Count-eq1) 'Prepared tools missing or duplicate'
    NeedPin ($matches[0].sha256-is[string]-and$matches[0].sha256-cmatch'^[0-9A-F]{64}$') 'Prepared tool digest is invalid'
  }
  return $Pin
}

function Get-R19TimedPathOuterCaptureDisposition {
  param([object]$Summary,[object]$Step,[string]$CandidateId,[string]$Mode)
  $accepted=$false;$reasons=@()
  try{
    foreach($field in @('cleanup_proven','hardware_interaction','acceptance_eligible','deployment_authorized')){
      if($Summary.$field-isnot[bool]){throw "Capture $field must be boolean"}
    }
    foreach($field in @('timed_out','termination_proven','process_tree_termination_proven')){
      if($Step.$field-isnot[bool]){throw "Child $field must be boolean"}
    }
    if($Summary.schema-cne'vc-lora-r19-timed-path-capture-v1'-or
      $Summary.result-cne'CAPTURE_COMPLETE_OBSERVATIONS_ONLY'-or
      $Summary.candidate_id-cne$CandidateId-or$Summary.mode-cne$Mode-or
      $Summary.capture_seconds-ne40-or-not$Summary.cleanup_proven-or
      -not$Summary.hardware_interaction-or$Summary.acceptance_eligible-or
      $Summary.deployment_authorized-or$Step.exit_code-ne0-or
      $Step.timed_out-or-not$Step.termination_proven-or
      -not$Step.process_tree_termination_proven){throw 'Timed-path capture acquisition contract failed'}
    $accepted=$true
  }catch{$reasons+= $_.Exception.Message}
  [pscustomobject][ordered]@{acceptable=$accepted;evidence_contract_proven=$accepted
    classification='TIMED_PATH_ACQUISITION_NOT_PRODUCT_ACCEPTANCE'
    status=if($accepted){'ACQUIRED_OBSERVATIONS_ONLY'}else{'INVALID_CAPTURE'}
    timing_sla_result='NOT_EVALUATED';timing_sla_failure_admitted_for_stage_read=$false
    tail_stall_failure_admitted_for_stage_read=$false
    alive_tail_stall_failure_admitted_for_stage_read=$false;alive_tail_raw_replay=$null
    boundary_partial_failure_admitted_for_stage_read=$false;boundary_partial_raw_replay=$null
    summary_path='';summary_sha256='';rejection_reasons=$reasons}
}

function Get-R19TimedPathOuterOutcome {
  param([object]$Evaluation,[string]$Failure,[bool]$Saved)
  $valid=$null-ne$Evaluation-and[bool]$Evaluation.PSObject.Properties['schema']-and
    $Evaluation.schema-ceq'vc-lora-r19-timed-path-normalization-v1'-and
    [string]::IsNullOrEmpty($Failure)-and$Saved
  [pscustomobject]@{result=$(if($valid){'PASS'}else{'FAIL'})
    status=$(if($valid){'PASS_TIMED_PATH_EVIDENCE_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'}else{'FAIL_TIMED_PATH_NORMALIZATION_R18_RESTORED'})
    acceptance_eligible=$false;deployment_authorized=$false}
}
