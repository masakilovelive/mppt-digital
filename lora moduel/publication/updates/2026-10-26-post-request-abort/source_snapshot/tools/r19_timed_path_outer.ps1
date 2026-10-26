# Pure contracts for the opt-in timed-path orchestration. No device access on import.
function Get-R19TimedPathOuterToolPaths {
  param([bool]$AuxReadinessDiagnostics=$false,
    [bool]$DiagnosticUsbFailureDiagnostics=$false,
    [bool]$ParamListDiagnostics=$false,[bool]$GrantDiagnostics=$false,
    [bool]$GrantReservationDiagnostics=$false,[bool]$GrantReservationStopDiagnostics=$false,[bool]$GrantAgreementDiagnostics=$false,[bool]$GrantReservationFatalDiagnostics=$false)
  if($DiagnosticUsbFailureDiagnostics-and-not$AuxReadinessDiagnostics){throw 'Diagnostic USB failure mode requires AUX diagnostics'}
  if($ParamListDiagnostics-and(-not$AuxReadinessDiagnostics-or-not$DiagnosticUsbFailureDiagnostics)){throw 'Parameter-list diagnostics require AUX and diagnostic USB failure mode'}
  if($GrantDiagnostics-and(-not$AuxReadinessDiagnostics-or-not$DiagnosticUsbFailureDiagnostics)){throw 'Grant diagnostics require AUX and diagnostic USB failure mode'}
  if($GrantReservationDiagnostics-and(-not$GrantDiagnostics-or-not$ParamListDiagnostics)){throw 'Grant reservation requires Grant and parameter-list diagnostics'}
  if($GrantReservationStopDiagnostics-and-not$GrantReservationDiagnostics){throw 'STOP128 requires explicit Grant reservation diagnostics'}
  if($GrantAgreementDiagnostics-and-not$GrantReservationStopDiagnostics){throw 'Agreement requires explicit STOP diagnostics'}
  if($GrantReservationFatalDiagnostics-and-not($GrantAgreementDiagnostics-and$GrantReservationStopDiagnostics)){throw 'Fatal diagnostics require explicit agreement and STOP diagnostics'}
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
  if($ParamListDiagnostics){$paths+=,'tools/r19_param_list_diagnostics.ps1'}
  if($GrantDiagnostics){$paths+=,'tools/read_r19_grant_diagnostic_record.ps1'}
  if($GrantReservationDiagnostics){$paths+=@('tools/r19_grant_reservation_wire.ps1','tools/r19_grant_reservation_workflow.ps1','tools/read_r19_grant_reservation_record.ps1','tools/r19_grant_reservation_contract.ps1')}
  if($GrantReservationStopDiagnostics){$paths+=,'tools/read_r19_grant_reservation_stop_record.ps1'}
  if($GrantReservationFatalDiagnostics){$paths+=,'tools/read_r19_grant_reservation_fatal_record.ps1'}
  $paths
}

function Assert-R19TimedPathPreparedContract {
  param([object]$Pin,[ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode,
    [bool]$AuxReadinessDiagnostics=$false,
    [bool]$DiagnosticUsbFailureDiagnostics=$false,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [bool]$ParamListDiagnostics=$false,[bool]$GrantDiagnostics=$false,
    [bool]$GrantReservationDiagnostics=$false,[bool]$GrantReservationStopDiagnostics=$false,[string]$RepoRoot='',[bool]$GrantAgreementDiagnostics=$false,[bool]$GrantReservationFatalDiagnostics=$false)
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
  $preparedParamList=$false
  if($null-ne$Pin.PSObject.Properties['param_list_diagnostics']){
    NeedPin ($Pin.param_list_diagnostics-is[bool]) 'Prepared parameter-list option must be boolean'
    $preparedParamList=$Pin.param_list_diagnostics
  }
  NeedPin ($preparedParamList-eq$ParamListDiagnostics) 'Prepared parameter-list option differs'
  $preparedGrant=$false
  if($null-ne$Pin.PSObject.Properties['grant_diagnostics']){
    NeedPin ($Pin.grant_diagnostics-is[bool]) 'Prepared Grant option must be boolean'
    $preparedGrant=$Pin.grant_diagnostics
  }
  NeedPin ($preparedGrant-eq$GrantDiagnostics) 'Prepared Grant option differs'
  $preparedReservation=$false
  if($null-ne$Pin.PSObject.Properties['grant_reservation_diagnostics']){
    NeedPin ($Pin.grant_reservation_diagnostics-is[bool]) 'Prepared Grant reservation option must be boolean'
    $preparedReservation=$Pin.grant_reservation_diagnostics
  }
  NeedPin ($preparedReservation-eq$GrantReservationDiagnostics) 'Prepared Grant reservation option differs'
  $preparedStop=$false
  if($null-ne$Pin.PSObject.Properties['grant_reservation_stop_diagnostics']){
    NeedPin ($Pin.PSObject.Properties['grant_reservation_stop_diagnostics'].Name-ceq'grant_reservation_stop_diagnostics'-and$Pin.grant_reservation_stop_diagnostics-is[bool]) 'Prepared STOP128 option must be exact Boolean'
    $preparedStop=$Pin.grant_reservation_stop_diagnostics
  }
  NeedPin ($preparedStop-eq$GrantReservationStopDiagnostics) 'Prepared STOP128 option differs'
  $preparedAgreement=$false
  if($null-ne$Pin.PSObject.Properties['grant_agreement_diagnostics']){
    NeedPin ($Pin.PSObject.Properties['grant_agreement_diagnostics'].Name-ceq'grant_agreement_diagnostics'-and$Pin.grant_agreement_diagnostics-is[bool]) 'Prepared agreement option must be exact Boolean'
    $preparedAgreement=$Pin.grant_agreement_diagnostics
  }
  NeedPin ($preparedAgreement-eq$GrantAgreementDiagnostics) 'Prepared agreement option differs'
  $preparedFatal=$false
  if($null-ne$Pin.PSObject.Properties['grant_reservation_fatal_diagnostics']){
    NeedPin ($Pin.PSObject.Properties['grant_reservation_fatal_diagnostics'].Name-ceq'grant_reservation_fatal_diagnostics'-and$Pin.grant_reservation_fatal_diagnostics-is[bool]) 'Prepared fatal option must be exact Boolean'
    $preparedFatal=$Pin.grant_reservation_fatal_diagnostics
  }
  NeedPin ($preparedFatal-eq$GrantReservationFatalDiagnostics) 'Prepared fatal option differs'
  NeedPin (-not$GrantReservationFatalDiagnostics-or($GrantAgreementDiagnostics-and$GrantReservationStopDiagnostics)) 'Prepared fatal requires agreement and STOP'
  NeedPin (-not$GrantAgreementDiagnostics-or$GrantReservationStopDiagnostics) 'Prepared agreement requires STOP'
  NeedPin (-not$GrantReservationStopDiagnostics-or$GrantReservationDiagnostics) 'Prepared STOP128 requires Grant reservation'
  if($GrantReservationStopDiagnostics){
    NeedPin (-not[string]::IsNullOrWhiteSpace($RepoRoot)) 'Prepared STOP128 requires explicit canonical repository binding'
    . (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
    [void](Assert-R19GrantReservationCandidateContract -Value $Pin.grant_reservation_contract -RepoRoot $RepoRoot -Enabled $true -CancellationEnabled $true -AgreementEnabled $GrantAgreementDiagnostics -FatalEnabled $GrantReservationFatalDiagnostics)
    [void](Assert-R19GrantReservationStopCandidateContract -Value $Pin.grant_reservation_stop_contract -RepoRoot $RepoRoot -Enabled $true -AgreementEnabled $GrantAgreementDiagnostics -FatalEnabled $GrantReservationFatalDiagnostics)
  }else{NeedPin ($null-eq$Pin.PSObject.Properties['grant_reservation_stop_contract']) 'Undeclared prepared STOP128 contract'}
  if($GrantAgreementDiagnostics){
    NeedPin ($null-ne$Pin.PSObject.Properties['grant_agreement_contract']-and$Pin.PSObject.Properties['grant_agreement_contract'].Name-ceq'grant_agreement_contract') 'Prepared agreement contract absent'
    [void](Assert-R19GrantAgreementCandidateContract -Value $Pin.grant_agreement_contract -RepoRoot $RepoRoot -Enabled $true -FatalEnabled $GrantReservationFatalDiagnostics)
  }else{NeedPin ($null-eq$Pin.PSObject.Properties['grant_agreement_contract']) 'Undeclared prepared agreement contract'}
  if($GrantReservationFatalDiagnostics){
    NeedPin ($null-ne$Pin.PSObject.Properties['grant_reservation_fatal_contract']-and$Pin.PSObject.Properties['grant_reservation_fatal_contract'].Name-ceq'grant_reservation_fatal_contract') 'Prepared fatal contract absent'
    [void](Assert-R19GrantReservationFatalCandidateContract -Value $Pin.grant_reservation_fatal_contract -RepoRoot $RepoRoot -Enabled $true)
  }else{NeedPin ($null-eq$Pin.PSObject.Properties['grant_reservation_fatal_contract']) 'Undeclared prepared fatal contract'}
  NeedPin (-not$GrantReservationDiagnostics-or($GrantDiagnostics-and$ParamListDiagnostics-and$Mode-ceq'ExplicitHostArm'-and$ReadComparisonMode-ceq'None')) 'Grant reservation requires Grant and parameter-list diagnostics without comparison'
  if($GrantReservationDiagnostics){
    NeedPin ($null-ne$Pin.PSObject.Properties['grant_reservation_contract']) 'Prepared Grant reservation contract absent'
    NeedPin (($Pin.reservation_prepare_seconds-is[int]-or$Pin.reservation_prepare_seconds-is[long])-and$Pin.reservation_prepare_seconds-eq15) 'Prepared Grant reservation preparation duration differs'
  }else{
    NeedPin ($null-eq$Pin.PSObject.Properties['grant_reservation_contract']-and$null-eq$Pin.PSObject.Properties['reservation_prepare_seconds']) 'Prepared Grant reservation metadata requires explicit opt-in'
  }
  NeedPin (-not$GrantDiagnostics-or($Mode-ceq'ExplicitHostArm'-and$AuxReadinessDiagnostics-and$DiagnosticUsbFailureDiagnostics-and$ReadComparisonMode-ceq'None')) 'Grant diagnostics require ExplicitHostArm AUX/USB without read comparison'
  NeedPin (-not$ParamListDiagnostics-or($Mode-ceq'ExplicitHostArm'-and$AuxReadinessDiagnostics-and$DiagnosticUsbFailureDiagnostics-and$ReadComparisonMode-ceq'None')) 'Parameter-list diagnostics require ExplicitHostArm AUX/diagnostic mode without read comparison'
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
  if($GrantDiagnostics){$expectedLatest='runs/candidates/R19-GRANT-DIAGNOSTIC-USB-FAILURE-AUX-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
  if($GrantReservationDiagnostics){$expectedLatest='runs/candidates/R19-GRANT-RESERVATION-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
  if($GrantReservationStopDiagnostics){$expectedLatest='runs/candidates/R19-GRANT-RESERVATION-STOP-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
  if($GrantAgreementDiagnostics){$expectedLatest='runs/candidates/R19-GRANT-AGREEMENT-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
  if($GrantReservationFatalDiagnostics){$expectedLatest='runs/candidates/R19-GRANT-FATAL-EXPLICIT-HOST-ARM-CANDIDATE-BUILD-001/latest.json'}
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
  $expected=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $AuxReadinessDiagnostics -DiagnosticUsbFailureDiagnostics $DiagnosticUsbFailureDiagnostics -ParamListDiagnostics $ParamListDiagnostics -GrantDiagnostics $GrantDiagnostics -GrantReservationDiagnostics $GrantReservationDiagnostics -GrantReservationStopDiagnostics $GrantReservationStopDiagnostics -GrantAgreementDiagnostics $GrantAgreementDiagnostics -GrantReservationFatalDiagnostics $GrantReservationFatalDiagnostics)
  NeedPin ($Pin.tools-is[array]-and$Pin.tools.Count-eq$expected.Count) 'Prepared tool count differs'
  foreach($path in $expected){
    $toolRows=@($Pin.tools|Where-Object{$_.path-ceq$path})
    NeedPin ($toolRows.Count-eq1) 'Prepared tools missing or duplicate'
    NeedPin ($toolRows[0].sha256-is[string]-and$toolRows[0].sha256-cmatch'^[0-9A-F]{64}$') 'Prepared tool digest is invalid'
    if($GrantAgreementDiagnostics){NeedPin ($toolRows[0].sha256-ceq(Get-FileHash -LiteralPath (Join-Path $RepoRoot $path) -Algorithm SHA256 -ErrorAction Stop).Hash) 'Prepared agreement tool source digest differs'}
  }
  return $Pin
}

function Assert-R19ParamListCaptureContract {
  param([object]$Summary,[bool]$Enabled=$false)
  function NeedLoad([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
  function LoadInteger($Value){return (($Value-is[int]-or$Value-is[long])-and$Value-ge0)}
  function LoadTicks($Value,[string]$Name){
    NeedLoad ($Value-is[string]-and$Value-cmatch'^(0|[1-9][0-9]*)$') "Parameter-list $Name must be an exact tick string"
    $number=[Numerics.BigInteger]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)
    NeedLoad ($number-le[Numerics.BigInteger]::Parse('9223372036854775807')) "Parameter-list $Name is out of range"
    return $number
  }
  $capturedEnabled=$false
  if($null-ne$Summary.PSObject.Properties['param_list_diagnostics_enabled']){
    NeedLoad ($Summary.param_list_diagnostics_enabled-is[bool]) 'Capture parameter-list option must be boolean'
    $capturedEnabled=$Summary.param_list_diagnostics_enabled
  }
  NeedLoad ($capturedEnabled-eq$Enabled) 'Capture parameter-list option differs'
  if(-not$Enabled){
    NeedLoad ($null-eq$Summary.PSObject.Properties['param_list_diagnostics']-or$null-eq$Summary.param_list_diagnostics) 'Unexpected parameter-list ledger in legacy capture'
    return
  }
  NeedLoad ($null-ne$Summary.PSObject.Properties['param_list_diagnostics']) 'Capture parameter-list ledger is missing'
  $ledger=$Summary.param_list_diagnostics
  NeedLoad ($null-ne$ledger-and$ledger-isnot[string]-and$ledger-isnot[ValueType]-and$ledger-isnot[array]) 'Capture parameter-list ledger must be an object'
  NeedLoad ($ledger.schema-ceq'vc-lora-r19-param-list-diagnostics-v1') 'Parameter-list ledger schema differs'
  NeedLoad ((LoadInteger $ledger.target_count)-and$ledger.target_count-eq932-and$ledger.deadline_us-is[string]-and$ledger.deadline_us-ceq'30000000') 'Parameter-list target/deadline differs'
  foreach($name in @('acceptance_eligible','deployment_authorized')){NeedLoad ($ledger.$name-is[bool]-and-not$ledger.$name) 'Parameter-list observations never grant product authority'}
  NeedLoad ($ledger.clock_domain_id-is[string]-and$ledger.clock_domain_id-ceq$Summary.clock_domain_id-and$ledger.frequency-is[string]-and$ledger.frequency-ceq$Summary.frequency) 'Parameter-list ledger clock differs from capture'
  NeedLoad ((LoadTicks $ledger.frequency 'frequency')-gt0) 'Parameter-list clock frequency is zero'
  NeedLoad ((LoadInteger $ledger.request_attempts)-and$ledger.request_attempts-le1) 'Parameter-list request must be at most one attempt'
  NeedLoad (@($Summary.roles).Count-eq2) 'Parameter-list capture requires exactly two role ledgers'
  $privateCalls=0
  foreach($name in @('vehicle','ground')){
    $rows=@($Summary.roles|Where-Object{$_.role-ceq$name})
    NeedLoad ($rows.Count-eq1) 'Parameter-list capture role ledger is absent or duplicated'
    $privateCalls+=@($rows[0].writes).Count
  }
  $reservationWrites=0
  if($null-ne$Summary.PSObject.Properties['grant_reservation_diagnostics']){
    NeedLoad ($Summary.grant_reservation_diagnostics-is[bool]) 'Reservation capture option must be boolean'
    if($Summary.grant_reservation_diagnostics){
      NeedLoad ($null-ne$Summary.PSObject.Properties['grant_reservation_workflow']) 'Reservation command ledger missing'
      $commands=@($Summary.grant_reservation_workflow.commands)
      $maxCommands=8
      if($null-ne$Summary.PSObject.Properties['grant_reservation_stop_diagnostics']){
        NeedLoad ($Summary.PSObject.Properties['grant_reservation_stop_diagnostics'].Name-ceq'grant_reservation_stop_diagnostics'-and$Summary.grant_reservation_stop_diagnostics-is[bool]) 'STOP128 capture option must be exact Boolean'
        if($Summary.grant_reservation_stop_diagnostics){
          $agreementSelected=$null-ne$Summary.PSObject.Properties['grant_agreement_diagnostics']-and$Summary.PSObject.Properties['grant_agreement_diagnostics'].Name-ceq'grant_agreement_diagnostics'-and$Summary.grant_agreement_diagnostics-is[bool]-and$Summary.grant_agreement_diagnostics
          NeedLoad ($Summary.grant_reservation_workflow.cancellation_enabled-is[bool]-and$Summary.grant_reservation_workflow.cancellation_enabled-and$Summary.grant_reservation_workflow.wire_version-eq$(if($agreementSelected){3}else{2})) 'STOP128 command bound requires selected exact cancellation wire version'
          $maxCommands=if($agreementSelected){24}else{18}
        }
      }
      NeedLoad ($commands.Count-le$maxCommands) 'Reservation command ledger exceeds selected bounded command count'
      foreach($command in $commands){
        NeedLoad ($null-ne$command.PSObject.Properties['started_ticks']) 'Reservation command attempt marker missing'
        if($null-ne$command.started_ticks){$null=LoadTicks $command.started_ticks 'reservation write start';$reservationWrites++}
      }
    }
  }
  NeedLoad ($privateCalls-le3-and(LoadInteger $Summary.serial_write_calls)-and$Summary.serial_write_calls-eq($privateCalls+$ledger.request_attempts+$reservationWrites)) 'Parameter-list request attempt differs from serial write ledger count'
  foreach($name in @('snapshot_30s','final')){NeedLoad ($null-ne$ledger.$name-and$ledger.$name-isnot[string]-and$ledger.$name-isnot[ValueType]-and$ledger.$name-isnot[array]) "Parameter-list $name observation object missing"}
  if($ledger.request_attempts-eq0){
    NeedLoad ($null-eq$ledger.request) 'Unattempted parameter-list request cannot have write evidence'
    return
  }
  $request=$ledger.request
  NeedLoad ($null-ne$request-and$request-isnot[string]-and$request-isnot[ValueType]-and$request-isnot[array]) 'Attempted parameter-list request requires write evidence'
  NeedLoad ((LoadInteger $request.expected_bytes)-and$request.expected_bytes-eq14-and$request.frame_sha256-is[string]-and$request.frame_sha256-ceq'FC3A47A83D35D44E96E044A216FDBF082805F9FACCDD5E4B9252E0C7026D4A75') 'Parameter-list request does not bind the exact frozen 14 bytes'
  NeedLoad ($request.local_write_api_accepted_only-is[bool]-and$request.local_write_api_accepted_only-and$request.delivery_proven-is[bool]-and-not$request.delivery_proven) 'Parameter-list write cannot claim remote delivery'
  NeedLoad ($request.api_exception_type-is[string]) 'Parameter-list exception type must be a string'
  NeedLoad ($null-eq$request.accepted_bytes-or((LoadInteger $request.accepted_bytes)-and$request.accepted_bytes-le14)) 'Parameter-list local acceptance is not an exact bounded count'
  $start=LoadTicks $request.write_started_ticks 'write start'
  $measurementStart=LoadTicks $Summary.measurement_start_ticks 'measurement start'
  $measurementEnd=LoadTicks $Summary.measurement_end_ticks 'measurement end'
  NeedLoad ($measurementStart-le$start-and$start-le$measurementEnd) 'Parameter-list request start is outside measurement window'
  if($null-ne$request.write_returned_ticks){NeedLoad ((LoadTicks $request.write_returned_ticks 'write return')-ge$start) 'Parameter-list request return precedes start'}
}

function Assert-R19GrantAgreementCaptureContract {
  param([object]$Summary,[bool]$Enabled=$false,[object]$Contract=$null,[string]$RepoRoot='',[bool]$GrantReservationFatalDiagnostics=$false)
  Set-StrictMode -Version Latest
  function NeedAgreement([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
  function ExactAgreementTicks($Value){NeedAgreement ($Value-is[string]-and$Value-cmatch'^(0|[1-9][0-9]*)$') 'Agreement ticks must be exact strings';$n=[Numerics.BigInteger]::Parse($Value);NeedAgreement ($n-le[long]::MaxValue) 'Agreement ticks exceed clock range';return $n}
  $selected=$false
  if($null-ne$Summary.PSObject.Properties['grant_agreement_diagnostics']){
    NeedAgreement ($Summary.PSObject.Properties['grant_agreement_diagnostics'].Name-ceq'grant_agreement_diagnostics'-and$Summary.grant_agreement_diagnostics-is[bool]) 'Capture agreement option must be exact Boolean'
    $selected=$Summary.grant_agreement_diagnostics
  }
  NeedAgreement ($selected-eq$Enabled) 'Capture agreement option differs'
  if(-not$Enabled){NeedAgreement ($null-eq$Summary.PSObject.Properties['grant_agreement_contract']) 'Undeclared capture agreement contract';return}
  NeedAgreement (-not[string]::IsNullOrWhiteSpace($RepoRoot)-and$null-ne$Contract) 'Agreement capture requires canonical repository and contract'
  . (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
  . (Join-Path $RepoRoot 'tools/r19_grant_reservation_wire.ps1')
  [void](Assert-R19GrantAgreementCandidateContract -Value $Contract -RepoRoot $RepoRoot -Enabled $true -FatalEnabled $GrantReservationFatalDiagnostics)
  NeedAgreement ($null-ne$Summary.PSObject.Properties['grant_agreement_contract']-and$Summary.PSObject.Properties['grant_agreement_contract'].Name-ceq'grant_agreement_contract'-and($Summary.grant_agreement_contract|ConvertTo-Json -Depth 24 -Compress)-ceq($Contract|ConvertTo-Json -Depth 24 -Compress)) 'Capture agreement capability binding differs'
  $w=$Summary.grant_reservation_workflow
  NeedAgreement ($w.schema-ceq'vc-lora-r19-grant-reservation-workflow-v1'-and$w.agreement_enabled-is[bool]-and$w.agreement_enabled-and$w.cancellation_enabled-is[bool]-and$w.cancellation_enabled-and($w.wire_version-is[int]-or$w.wire_version-is[long])-and$w.wire_version-eq3) 'Agreement requires explicit v3 cancellation workflow'
  NeedAgreement ($w.candidate_id-ceq$Summary.candidate_id-and$w.handoff_sha256-ceq$Summary.handoff_sha256-and$w.flash_evidence_sha256-ceq$Summary.flash_evidence_sha256-and$w.clock_domain_id-ceq$Summary.clock_domain_id-and$w.frequency-ceq$Summary.frequency) 'Agreement workflow provenance or clock differs'
  foreach($field in @('high_speed_success_proven','rf_delivery_proven','acceptance_authorized','deployment_authorized','commit_is_irrevocable')){NeedAgreement ($w.$field-is[bool]-and-not$w.$field) 'USB agreement must not claim RF, irrevocability or product success'}
  NeedAgreement (($w.param_attempts-is[int]-or$w.param_attempts-is[long])-and$w.param_attempts-ge0-and$w.param_attempts-le1-and@($w.commands).Count-le24) 'Agreement requests and OUT commands are strictly bounded'
  NeedAgreement (($w.maximum_commands-is[int]-or$w.maximum_commands-is[long])-and$w.maximum_commands-eq24-and$w.maximum_rounds-eq2-and$w.maximum_cancellations-eq1) 'Agreement command and cancellation budgets differ'
  if($null-ne$w.PSObject.Properties['measurement_kind']){
    NeedAgreement ($w.PSObject.Properties['measurement_kind'].Name-ceq'measurement_kind'-and$w.measurement_kind-ceq'PASSIVE_AFTER_FAILED_PREPARATION'-and$w.status-ceq'Failed'-and$w.param_attempts-eq0) 'Passive preparation capture cannot claim product attempt or successful workflow'
    $prepare=ExactAgreementTicks $w.prepare_deadline_ticks;$start=ExactAgreementTicks $w.measurement_start_ticks
    $plannedEnd=ExactAgreementTicks $w.planned_passive_capture_end_ticks;$observed=ExactAgreementTicks $w.passive_boundary_observed_ticks
    NeedAgreement ($start-eq$prepare-and$plannedEnd-eq$prepare+40*(ExactAgreementTicks $w.frequency)-and$observed-ge$prepare-and$observed-lt$plannedEnd) 'Passive preparation time window was reset, extended or mislabeled'
    NeedAgreement ($Summary.measurement_start_ticks-ceq$w.measurement_start_ticks-and(ExactAgreementTicks $Summary.measurement_end_ticks)-ge$plannedEnd) 'Passive capture summary does not retain the original planned 40s observation window'
    NeedAgreement ($null-eq$w.terminal_abort.capture_deadline_ticks-or$w.terminal_abort.capture_deadline_ticks-ceq$w.planned_passive_capture_end_ticks) 'Passive capture and terminal cleanup disagree on their immutable end'
  }
  $rawByRole=@{}
  function CheckAgreementFrame($Observation,[string]$Role,[string]$Opcode,$Write){
    NeedAgreement ($null-ne$Observation-and$null-ne$Write-and$Write.write_success-is[bool]-and$Write.write_success-and$Write.accepted_bytes-eq66-and$null-ne$Write.started_ticks-and$null-ne$Write.returned_ticks) 'Agreement ACK requires one complete matching OUT write'
    [byte[]]$outFrame=[Convert]::FromBase64String($Write.frame_base64)
    NeedAgreement ($null-ne$Write.bytes-and[Convert]::ToBase64String([byte[]]$Write.bytes)-ceq$Write.frame_base64) 'Agreement OUT byte array differs from the recorded command frame'
    $outDecoded=ConvertFrom-R19GrantReservationFrame -Bytes $outFrame -AgreementEnabled $true
    $expectedOut=if($Opcode-ceq'CommitAck'){'CommitRequest'}else{'AbortRequest'}
    NeedAgreement ($outDecoded.valid-and$outDecoded.version-eq3-and$outDecoded.component-eq197-and$outDecoded.role-ceq$Role-and$outDecoded.opcode-ceq$expectedOut-and$Write.opcode-ceq$expectedOut-and$Write.role-ceq$Role-and$Write.local_write_api_accepted_only-is[bool]-and$Write.local_write_api_accepted_only-and$Write.remote_delivery_proven-is[bool]-and-not$Write.remote_delivery_proven) 'Agreement ACK matching OUT is not canonical local-only wire3 command'
    $matchingWrites=@($w.commands|Where-Object{$_.index-eq$Write.index-and$_.role-ceq$Role-and$_.frame_base64-ceq$Write.frame_base64-and$_.started_ticks-ceq$Write.started_ticks})
    NeedAgreement ($matchingWrites.Count-eq1) 'Agreement ACK OUT not uniquely present in the bounded command ledger'
    [byte[]]$frame=[Convert]::FromBase64String($Observation.frame_base64)
    $decoded=ConvertFrom-R19GrantReservationFrame -Bytes $frame -AgreementEnabled $true
    NeedAgreement ($decoded.valid-and$decoded.version-eq3-and$decoded.component-eq198-and$decoded.role-ceq$Role-and$decoded.opcode-ceq$Opcode) 'Agreement ACK raw CRC/direction/role/opcode differs'
    NeedAgreement (($Observation.decoded|ConvertTo-Json -Depth 12 -Compress)-ceq($decoded|ConvertTo-Json -Depth 12 -Compress)) 'Agreement ACK decoded view differs from actual frame'
    $hello=$w.('hello_'+$Role)
    NeedAgreement ($null-ne$hello-and$null-ne$w.prepared-and$decoded.boot_id-ceq$hello.boot_id-and$decoded.usb_epoch-ceq$hello.usb_epoch-and$decoded.reader_session-ceq$w.reader_session-and$decoded.slot_nonce-ceq$w.slot_nonce) 'Agreement ACK identity/session differs'
    foreach($key in @('boot_id','usb_epoch','reader_session','slot_nonce','grant_session','grant_cycle','slot_token','generation')){NeedAgreement ($outDecoded.$key-ceq$decoded.$key) 'Agreement ACK and matching OUT tuple differ'}
    foreach($key in @('grant_session','grant_cycle','slot_token','generation')){NeedAgreement ($decoded.$key-ceq$w.prepared.$key) 'Agreement ACK tuple differs'}
    [uint64]$minimumMs=[uint64]$hello.device_ms
    $localBound=if($Role-ceq'ground'){$w.bound}else{$w.prepared}
    if($null-ne$localBound-and[uint64]$localBound.device_ms-gt$minimumMs){$minimumMs=[uint64]$localBound.device_ms}
    if($Opcode-ceq'AbortAck'){
      foreach($prior in @($w.('commit_'+$Role),$(if($Role-ceq'ground'){$w.held}else{$w.tail_ready}))){if($null-ne$prior-and[uint64]$prior.device_ms-gt$minimumMs){$minimumMs=[uint64]$prior.device_ms}}
      if($null-ne$w.terminal_abort.trigger-and$w.terminal_abort.trigger.role-ceq$Role-and[uint64]$w.terminal_abort.trigger.decoded.device_ms-gt$minimumMs){$minimumMs=[uint64]$w.terminal_abort.trigger.decoded.device_ms}
    }
    NeedAgreement ([uint64]$decoded.device_ms-ge$minimumMs) 'Agreement ACK MCU time regresses before its current local boundary'
    $read=ExactAgreementTicks $Observation.read_completed_ticks;$observed=ExactAgreementTicks $Observation.observation_ticks
    NeedAgreement ($read-ge(ExactAgreementTicks $Write.started_ticks)-and$read-le$observed-and(ExactAgreementTicks $Write.returned_ticks)-ge(ExactAgreementTicks $Write.started_ticks)) 'Agreement ACK native chronology differs'
    $rows=@($Summary.roles|Where-Object{$_.role-ceq$Role})
    NeedAgreement ($rows.Count-eq1-and$rows[0].raw_available-is[bool]-and$rows[0].raw_available-and$rows[0].raw_saved-is[bool]-and$rows[0].raw_saved-and$rows[0].reader_continuous-is[bool]-and$rows[0].reader_continuous) 'Agreement ACK needs the uninterrupted physical-role raw owner'
    $r=$rows[0]
    if(-not$rawByRole.ContainsKey($Role)){
      [byte[]]$raw=[Convert]::FromBase64String($r.raw_base64)
      $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','')}finally{$sha.Dispose()}
      NeedAgreement ($raw.Length-eq$r.raw_bytes-and$hash-ceq$r.raw_sha256) 'Agreement ACK raw size/hash differs'
      $rawByRole[$Role]=$raw
    }
    [byte[]]$raw=$rawByRole[$Role]
    NeedAgreement (($Observation.raw_offset-is[int]-or$Observation.raw_offset-is[long])-and$Observation.raw_offset-ge0-and$Observation.raw_offset-le$raw.Length-66) 'Agreement ACK raw coordinate is outside captured stream'
    [long]$offset=$Observation.raw_offset
    for($i=0;$i-lt66;$i++){NeedAgreement ($raw[$offset+$i]-eq$frame[$i]) 'Agreement ACK frame differs from captured bytes'}
    $blocks=@($r.blocks|Where-Object{[long]$_.offset-le$offset+65-and[long]$_.offset+[long]$_.count-gt$offset+65})
    NeedAgreement ($blocks.Count-eq1-and$blocks[0].end_ticks-ceq$Observation.read_completed_ticks-and$blocks[0].clock_domain_id-ceq$Summary.clock_domain_id-and$blocks[0].frequency-ceq$Summary.frequency) 'Agreement ACK timestamp is not the actual native read completing that frame'
  }
  foreach($role in @('vehicle','ground')){
    $commit=$w.('commit_'+$role)
    if($null-ne$commit){
      $observations=@($w.observations|Where-Object{$_.role-ceq$role-and$_.decoded.opcode-ceq'CommitAck'})
      $writes=@($w.commands|Where-Object{$_.role-ceq$role-and$_.opcode-ceq'CommitRequest'-and$_.write_success})
      # At most two cancelled preparation rounds are supported. Select the
      # current nonce, never silently treat an old-round ACK as current consent.
      $observations=@($observations|Where-Object{$_.decoded.slot_nonce-ceq$w.slot_nonce})
      $writes=@($writes|Where-Object{$_.round-eq$w.round})
      NeedAgreement ($observations.Count-eq1-and$writes.Count-eq1) 'Current bilateral commit must have unique ACK/write evidence'
      CheckAgreementFrame $observations[0] $role CommitAck $writes[0]
      NeedAgreement (($commit|ConvertTo-Json -Depth 12 -Compress)-ceq($observations[0].decoded|ConvertTo-Json -Depth 12 -Compress)) 'Current commit view differs from native evidence'
      if($w.param_attempts-eq1){NeedAgreement ((ExactAgreementTicks $observations[0].read_completed_ticks)-le(ExactAgreementTicks $w.param_write_started_ticks)) 'PARAM started before bilateral CommitAck'}
    }elseif($w.param_attempts-eq1){throw 'Attempted PARAM requires both actual CommitAck frames'}
  }
  if($w.status-ceq'CommittedReadyForOneParam'){NeedAgreement ($null-ne$w.commit_ground-and$null-ne$w.commit_vehicle-and$w.param_attempts-eq0) 'Committed-ready status requires bilateral ACK and zero prior PARAM'}
  NeedAgreement ($w.terminal_abort.phase-cin@('NOT_REQUIRED','ABORT_UNCONFIRMED','ABORTED_CONFIRMED')) 'Unknown terminal abort evidence phase'
  $ackCount=0
  foreach($role in @('vehicle','ground')){
    $r=$w.terminal_abort.roles.$role
    NeedAgreement (($r.attempts-is[int]-or$r.attempts-is[long])-and$r.attempts-ge0-and$r.attempts-le1) 'Terminal abort per-role attempt limit differs'
    if($null-ne$r.ack){
      NeedAgreement ($r.attempts-eq1-and$w.status-ceq'Failed'-and$r.write_success-is[bool]-and$r.write_success-and$r.accepted_bytes-eq66-and$r.started_ticks-ceq$r.command.started_ticks-and$r.returned_ticks-ceq$r.command.returned_ticks) 'AbortAck cannot revive normal workflow or forge its independent cleanup ledger'
      CheckAgreementFrame $r.ack $role AbortAck $r.command;$ackCount++
    }
  }
  NeedAgreement (($w.terminal_abort.phase-ceq'ABORTED_CONFIRMED')-eq($ackCount-eq2)) 'Bilateral retirement requires both actual tuple-bound AbortAck frames'
}

function Assert-R19GrantReservationFatalCaptureContract {
  param([object]$Summary,[bool]$Enabled=$false,[object]$Contract=$null,[string]$RepoRoot='')
  $selected=$false
  if($null-ne$Summary.PSObject.Properties['grant_reservation_fatal_diagnostics']){
    $p=$Summary.PSObject.Properties['grant_reservation_fatal_diagnostics']
    if($p.Name-cne'grant_reservation_fatal_diagnostics'-or$p.Value-isnot[bool]){throw 'Capture fatal option must be exact Boolean'}
    $selected=$p.Value
  }
  if($selected-ne$Enabled){throw 'Capture fatal option differs'}
  if(-not$Enabled){
    if($null-ne$Summary.PSObject.Properties['grant_reservation_fatal_contract']){throw 'Undeclared capture fatal contract'}
    return
  }
  if([string]::IsNullOrWhiteSpace($RepoRoot)-or$null-eq$Contract){throw 'Fatal capture requires canonical repository and contract'}
  . (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
  [void](Assert-R19GrantReservationFatalCandidateContract -Value $Contract -RepoRoot $RepoRoot -Enabled $true)
  $binding=$Summary.PSObject.Properties['grant_reservation_fatal_contract']
  if($null-eq$binding-or$binding.Name-cne'grant_reservation_fatal_contract'-or
      ($binding.Value|ConvertTo-Json -Depth 20 -Compress)-cne($Contract|ConvertTo-Json -Depth 20 -Compress)){throw 'Capture fatal capability binding differs'}
}

function Get-R19TimedPathOuterCaptureDisposition {
  param([object]$Summary,[object]$Step,[string]$CandidateId,[string]$Mode,
    [ValidateSet('None','GroundPauseResume')][string]$ReadComparisonMode='None',
    [bool]$ParamListDiagnostics=$false,[bool]$GrantReservationDiagnostics=$false,
    [object]$GrantReservationContract=$null,[bool]$GrantReservationStopDiagnostics=$false,
    [object]$GrantReservationStopContract=$null,[string]$RepoRoot='',
    [bool]$GrantAgreementDiagnostics=$false,[object]$GrantAgreementContract=$null,
    [bool]$GrantReservationFatalDiagnostics=$false,[object]$GrantReservationFatalContract=$null)
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
    if($ParamListDiagnostics-and($Mode-cne'ExplicitHostArm'-or$ReadComparisonMode-cne'None')){throw 'Parameter-list capture mode is invalid'}
    Assert-R19ParamListCaptureContract -Summary $Summary -Enabled $ParamListDiagnostics
    Assert-R19GrantAgreementCaptureContract -Summary $Summary -Enabled $GrantAgreementDiagnostics -Contract $GrantAgreementContract -RepoRoot $RepoRoot -GrantReservationFatalDiagnostics $GrantReservationFatalDiagnostics
    if($GrantReservationFatalDiagnostics-or$null-ne$Summary.PSObject.Properties['grant_reservation_fatal_diagnostics']-or$null-ne$Summary.PSObject.Properties['grant_reservation_fatal_contract']){
      Assert-R19GrantReservationFatalCaptureContract -Summary $Summary -Enabled $GrantReservationFatalDiagnostics -Contract $GrantReservationFatalContract -RepoRoot $RepoRoot
    }
    if($GrantReservationFatalDiagnostics-and-not($GrantAgreementDiagnostics-and$GrantReservationStopDiagnostics)){throw 'Fatal capture requires explicit agreement and STOP'}
    $reservationEnabled=$false
    if($null-ne$Summary.PSObject.Properties['grant_reservation_diagnostics']){
      if($Summary.grant_reservation_diagnostics-isnot[bool]){throw 'Capture Grant reservation selection must be boolean'}
      $reservationEnabled=$Summary.grant_reservation_diagnostics
    }
    if($reservationEnabled-ne$GrantReservationDiagnostics){throw 'Capture Grant reservation selection differs'}
    $stopEnabled=$false
    if($null-ne$Summary.PSObject.Properties['grant_reservation_stop_diagnostics']){
      if($Summary.PSObject.Properties['grant_reservation_stop_diagnostics'].Name-cne'grant_reservation_stop_diagnostics'-or$Summary.grant_reservation_stop_diagnostics-isnot[bool]){throw 'Capture STOP128 selection must be exact Boolean'}
      $stopEnabled=$Summary.grant_reservation_stop_diagnostics
    }
    if($stopEnabled-ne$GrantReservationStopDiagnostics){throw 'Capture STOP128 selection differs'}
    if($GrantReservationStopDiagnostics){
      if(-not$GrantReservationDiagnostics-or[string]::IsNullOrWhiteSpace($RepoRoot)){throw 'STOP128 capture requires reservation and canonical repository binding'}
      . (Join-Path $RepoRoot 'tools/r19_grant_reservation_contract.ps1')
      [void](Assert-R19GrantReservationCandidateContract -Value $GrantReservationContract -RepoRoot $RepoRoot -Enabled $true -CancellationEnabled $true -AgreementEnabled $GrantAgreementDiagnostics -FatalEnabled $GrantReservationFatalDiagnostics)
      [void](Assert-R19GrantReservationStopCandidateContract -Value $GrantReservationStopContract -RepoRoot $RepoRoot -Enabled $true -AgreementEnabled $GrantAgreementDiagnostics -FatalEnabled $GrantReservationFatalDiagnostics)
      if(($Summary.grant_reservation_stop_contract|ConvertTo-Json -Depth 20 -Compress)-cne($GrantReservationStopContract|ConvertTo-Json -Depth 20 -Compress)){throw 'Capture STOP128 capability binding differs'}
    }elseif($null-ne$Summary.PSObject.Properties['grant_reservation_stop_contract']){throw 'Undeclared capture STOP128 contract'}
    if($GrantReservationDiagnostics){
      if(-not$ParamListDiagnostics-or$Mode-cne'ExplicitHostArm'-or$ReadComparisonMode-cne'None'){throw 'Invalid Grant reservation capture mode'}
      if($null-eq$GrantReservationContract-or($Summary.grant_reservation_contract|ConvertTo-Json -Depth 20 -Compress)-cne($GrantReservationContract|ConvertTo-Json -Depth 20 -Compress)){throw 'Capture Grant reservation capability binding differs'}
      if(($Summary.reservation_prepare_seconds-isnot[int]-and$Summary.reservation_prepare_seconds-isnot[long])-or$Summary.reservation_prepare_seconds-ne15-or($Summary.measurement_seconds-isnot[int]-and$Summary.measurement_seconds-isnot[long])-or$Summary.measurement_seconds-ne40){throw 'Reservation preparation/measurement durations differ'}
    }elseif($null-ne$Summary.PSObject.Properties['grant_reservation_contract']){throw 'Undeclared capture reservation contract'}
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
    [object]$ComparisonEvaluation=$null,
    [bool]$ParamListDiagnostics=$false,[object]$ParamListEvaluation=$null)
  if($ParamListDiagnostics){
    $valid=$false
    try{
      $valid=$ReadComparisonMode-ceq'None'-and$Saved-and[string]::IsNullOrEmpty($Failure)-and
        $Evaluation.schema-ceq'vc-lora-r19-timed-path-normalization-v1'-and
        $ParamListEvaluation.schema-ceq'vc-lora-r19-param-list-diagnostics-v1'-and
        $ParamListEvaluation.acceptance_eligible-is[bool]-and-not$ParamListEvaluation.acceptance_eligible-and
        $ParamListEvaluation.deployment_authorized-is[bool]-and-not$ParamListEvaluation.deployment_authorized
    }catch{$valid=$false}
    return [pscustomobject]@{result=$(if($valid){'PASS'}else{'FAIL'})
      status=$(if($valid){'PASS_PARAM_LIST_DIAGNOSTICS_CAPTURED_R18_RESTORED_NOT_ACCEPTANCE'}else{'FAIL_PARAM_LIST_DIAGNOSTICS_R18_RESTORED'})
      acceptance_eligible=$false;deployment_authorized=$false}
  }
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
