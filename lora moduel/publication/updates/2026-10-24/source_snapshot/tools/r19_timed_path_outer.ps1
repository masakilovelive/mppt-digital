# Pure contracts for the opt-in timed-path orchestration. No device access on import.
function Get-R19TimedPathOuterToolPaths {
  param([bool]$AuxReadinessDiagnostics=$false,
    [bool]$DiagnosticUsbFailureDiagnostics=$false)
  if($DiagnosticUsbFailureDiagnostics-and-not$AuxReadinessDiagnostics){throw 'Diagnostic USB failure mode requires AUX diagnostics'}
  $paths=@('tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1',
    'tools/invoke_r19_candidate_app_flash_hil.ps1',
    'tools/read_r19_runtime_stage_jtag.ps1','tools/invoke_r19_jtag_preflash_gate.ps1',
    'tools/run_r19_timed_path_capture.ps1','tools/r19_timed_path_acquisition.ps1',
    'tools/r19_timed_path_outer.ps1','tools/read_r19_timed_path_record.ps1',
    'tools/read_r19_first_usb_failure_record.ps1','tools/r19_host_readiness_wire.ps1',
    'tools/r19_host_readiness_workflow.ps1','tools/r19_usb_clock_correlation.ps1',
    'tools/r19_timed_path_trace.ps1','tools/r19_startup_reader.cs',
    'tools/r19_continuous_reader.cs','tools/r19_candidate_artifact_common.ps1',
    'tools/verify_r19_candidate_artifact.ps1')
  if($AuxReadinessDiagnostics){$paths+=,'tools/read_r19_aux_readiness_record.ps1'}
  if($DiagnosticUsbFailureDiagnostics){$paths+=@('tools/read_r19_diagnostic_usb_failure_record.ps1','tools/r19_usb_role_contract.ps1')}
  $paths
}

function Assert-R19TimedPathPreparedContract {
  param([object]$Pin,[ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode,
    [bool]$AuxReadinessDiagnostics=$false,
    [bool]$DiagnosticUsbFailureDiagnostics=$false,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None')
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
  $preparedComparison='None'
  if($null-ne$Pin.PSObject.Properties['read_comparison_mode']){
    NeedPin ($Pin.read_comparison_mode-is[string]-and$Pin.read_comparison_mode-cin@('None','GroundPauseResume')) 'Prepared read comparison mode is invalid'
    $preparedComparison=$Pin.read_comparison_mode
  }
  NeedPin ($preparedComparison-ceq$ReadComparisonMode) 'Prepared read comparison mode differs'
  NeedPin ($ReadComparisonMode-ceq'None'-or($Mode-ceq'ExplicitHostArm'-and$AuxReadinessDiagnostics-and$DiagnosticUsbFailureDiagnostics)) 'Read comparison requires explicit AUX/diagnostic mode'
  NeedPin ($Pin.candidate_id-is[string]-and$Pin.candidate_id-cmatch'^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$') 'Unsafe candidate id'
  NeedPin ($Pin.latest_sha256-is[string]-and$Pin.latest_sha256-cmatch'^[0-9A-F]{64}$') 'Invalid latest digest'
  $leaf=if($Mode-ceq'SyncOnly'){'SYNC-ONLY'}else{'EXPLICIT-HOST-ARM'}
  if($DiagnosticUsbFailureDiagnostics){
    NeedPin ($AuxReadinessDiagnostics-and$Mode-ceq'ExplicitHostArm'-and
      $null-ne$Pin.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and
      $Pin.diagnostic_usb_failure_diagnostics-is[bool]-and$Pin.diagnostic_usb_failure_diagnostics) 'Prepared diagnostic USB failure mode requires AUX and ExplicitHostArm opt-in'
    NeedPin ($null-ne$Pin.PSObject.Properties['usb_role_capabilities']) 'Prepared USB role capabilities are missing'
    $cap=$Pin.usb_role_capabilities
    NeedPin ($cap.schema-ceq'vc-lora-r19-usb-role-capabilities-v1'-and$cap.mode-ceq$Mode-and
      $cap.implementation_bound-is[bool]-and$cap.implementation_bound) 'Prepared USB role capability contract invalid'
    NeedPin (@($cap.roles).Count-eq2) 'Prepared USB role count differs'
    foreach($spec in @(@('vehicle','SyncOnly',$false),@('ground','ExplicitHostArm',$true))){
      $matches=@($cap.roles|Where-Object{$_.role-ceq$spec[0]})
      NeedPin ($matches.Count-eq1) 'Prepared USB role is absent or duplicated'
      $role=$matches[0]
      NeedPin ($role.clock_request_reply-is[bool]-and$role.clock_request_reply-and$role.effective_mode-ceq$spec[1]-and
        $role.ready-is[bool]-and$role.ready-eq$spec[2]-and$role.arm-is[bool]-and$role.arm-eq$spec[2]) 'Prepared USB role feature escalation or missing clock handler'
    }
    $canonical=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1')
    NeedPin (@($cap.canonical_sources).Count-eq3) 'Prepared role source bindings differ'
    foreach($relative in $canonical){
      $binding=@($cap.canonical_sources|Where-Object{$_.path-ceq$relative})
      NeedPin ($binding.Count-eq1-and$binding[0].sha256-cmatch'^[0-9A-F]{64}$') 'Prepared role source digest missing or malformed'
    }
    $expectedLatest='runs/candidates/R19-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'
  }elseif($null-ne$Pin.PSObject.Properties['diagnostic_usb_failure_diagnostics']-and
      ($Pin.diagnostic_usb_failure_diagnostics-isnot[bool]-or$Pin.diagnostic_usb_failure_diagnostics)){
    throw 'Prepared diagnostic USB failure metadata requires explicit opt-in'
  }elseif($null-ne$Pin.PSObject.Properties['usb_role_capabilities']){
    throw 'Prepared role capability contract requires diagnostic USB failure mode'
  }
  if($AuxReadinessDiagnostics){
    NeedPin ($Mode-ceq'ExplicitHostArm'-and
      $null-ne$Pin.PSObject.Properties['aux_readiness_diagnostics']-and
      $Pin.aux_readiness_diagnostics-is[bool]-and$Pin.aux_readiness_diagnostics) 'Prepared AUX diagnostics require explicit opt-in and ExplicitHostArm'
    if(-not$DiagnosticUsbFailureDiagnostics){$expectedLatest='runs/candidates/R19-AUX-READINESS-EXPLICIT-HOST-ARM-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json'}
  }else{
    NeedPin ($null-eq$Pin.PSObject.Properties['aux_readiness_diagnostics']-or
      ($Pin.aux_readiness_diagnostics-is[bool]-and-not$Pin.aux_readiness_diagnostics)) 'AUX prepared pin requires explicit mode'
    $expectedLatest="runs/candidates/R19-TIMED-PATH-$leaf-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json"
  }
  NeedPin ($Pin.latest_path-ceq$expectedLatest) 'Prepared latest path differs from mode'
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
  $expected=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $AuxReadinessDiagnostics -DiagnosticUsbFailureDiagnostics $DiagnosticUsbFailureDiagnostics)
  NeedPin ($Pin.tools-is[array]-and$Pin.tools.Count-eq$expected.Count) 'Prepared tool count differs'
  foreach($path in $expected){
    $matches=@($Pin.tools|Where-Object{$_.path-ceq$path})
    NeedPin ($matches.Count-eq1) 'Prepared tools missing or duplicate'
    NeedPin ($matches[0].sha256-is[string]-and$matches[0].sha256-cmatch'^[0-9A-F]{64}$') 'Prepared tool digest is invalid'
  }
  return $Pin
}

function Get-R19TimedPathOuterCaptureDisposition {
  param([object]$Summary,[object]$Step,[string]$CandidateId,[string]$Mode,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None')
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
    if($ReadComparisonMode-cne'None'){
      if($null-eq$Summary.PSObject.Properties['read_comparison']-or$Summary.read_comparison.plan.mode-cne$ReadComparisonMode){throw 'Capture comparison mode mismatch'}
    }elseif($null-ne$Summary.PSObject.Properties['read_comparison']-and$Summary.read_comparison.plan.enabled){throw 'Unexpected read comparison intervention'}
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
  param([object]$Evaluation,[string]$Failure,[bool]$Saved,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [object]$ComparisonEvaluation=$null)
  if($ReadComparisonMode-cne'None'){
    $valid=$false
    try{
      $valid=$Saved-and[string]::IsNullOrEmpty($Failure)-and
        $ComparisonEvaluation.schema-ceq'vc-lora-r19-read-comparison-evaluation-v1'-and
        $ComparisonEvaluation.mode-ceq$ReadComparisonMode-and$ComparisonEvaluation.result-ceq'VALID_COMPARISON'-and
        $ComparisonEvaluation.valid-is[bool]-and$ComparisonEvaluation.valid-and
        $ComparisonEvaluation.causal_disposition-ceq'INDETERMINATE'
      foreach($field in @('physical_host_in_suppression_proven','root_cause_proven','acceptance_eligible','deployment_authorized')){
        if($ComparisonEvaluation.$field-isnot[bool]-or$ComparisonEvaluation.$field){$valid=$false}
      }
    }catch{$valid=$false}
    return [pscustomobject]@{result=$(if($valid){'PASS'}else{'FAIL'})
      status=$(if($valid){'PASS_READ_COMPARISON_EVIDENCE_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'}else{'FAIL_READ_COMPARISON_EVIDENCE_R18_RESTORED'})
      acceptance_eligible=$false;deployment_authorized=$false}
  }
  $valid=$null-ne$Evaluation-and[bool]$Evaluation.PSObject.Properties['schema']-and
    $Evaluation.schema-ceq'vc-lora-r19-timed-path-normalization-v1'-and
    [string]::IsNullOrEmpty($Failure)-and$Saved
  [pscustomobject]@{result=$(if($valid){'PASS'}else{'FAIL'})
    status=$(if($valid){'PASS_TIMED_PATH_EVIDENCE_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'}else{'FAIL_TIMED_PATH_NORMALIZATION_R18_RESTORED'})
    acceptance_eligible=$false;deployment_authorized=$false}
}
