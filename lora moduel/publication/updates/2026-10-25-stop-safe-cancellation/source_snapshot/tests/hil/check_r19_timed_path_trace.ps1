[CmdletBinding()]
param([string]$RepoRoot='',[string]$EvidenceDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $RepoRoot){$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$tool=Join-Path $RepoRoot 'tools/r19_timed_path_trace.ps1'
$script:checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL $Name"};$script:checks++;Write-Output "PASS $Name"}
function Reject($Evidence,[string]$Name){$threw=$false;try{$null=Get-R19TimedPathTraceEvaluation -Evidence $Evidence}catch{$threw=$true};Check $threw $Name}
function Clone($Object){$Object|ConvertTo-Json -Depth 40|ConvertFrom-Json}
function Identity {
 [pscustomobject]@{role='ground';candidate_id='offline-timed-path-candidate';build_fingerprint=@(1,2,3,4);boot_instance=@(5,6,7,8)
  usb_epoch=1;reader_session='123';nonce='5915759585527857153';frame_id='product-heartbeat-0001';frame_sha256=('A'*64)
  frame_kind='PRODUCT_HEARTBEAT';expected_frame_bytes=21}
}
function Event([string]$Kind,[int]$Ordinal,[string]$Domain,[string]$Timestamp,$Details,$Binding) {
 [pscustomobject]@{kind=$Kind;ordinal=$Ordinal;domain=$Domain;timestamp=$Timestamp;identity=(Clone $Binding);evidence_sha256=('B'*64);details=$Details}
}
function Fixture([switch]$Failed,[switch]$Completed,[switch]$Validated) {
 $identity=Identity
 $events=@(
  (Event 'PC_READ_STARTED' 0 'PC_TICKS' '9000000' ([pscustomobject]@{clock_domain_id='qpc-trace';reader_owner_verified=$true;frequency='1000000'}) $identity)
  (Event 'MCU_ARM_ACCEPTED' 1 'MCU_US' '1000000' ([pscustomobject]@{accepted=$true;device_clock_continuity_verified=$true}) $identity)
  (Event 'MCU_FRAME_ENQUEUED' 2 'MCU_US' '1000100' ([pscustomobject]@{frame_bytes=21}) $identity)
  (Event 'MCU_HWCDC_ACCEPTED' 3 'MCU_US' '1000200' ([pscustomobject]@{accepted_bytes=21}) $identity)
  (Event 'MCU_USB_PUBLISHED' 4 'MCU_US' '1000250' ([pscustomobject]@{publish_generation=3;ring_pending_bytes=0;stash_pending_bytes=0}) $identity)
  (Event 'MCU_USB_PICKUP_OBSERVED' 5 'MCU_US' '1000300' ([pscustomobject]@{pickup_generation=2}) $identity)
 )
 if($Failed){$events+=Event 'MCU_USB_FAILED' $events.Count 'MCU_US' '1106638' ([pscustomobject]@{budget_ms=106;started_us='1000400';finished_us='1106638';accepted_bytes=21;reason='LoopTimeout'}) $identity}
 if($Completed){$events+=Event 'MCU_USB_COMPLETED' $events.Count 'MCU_US' '1000400' ([pscustomobject]@{completed_bytes=21}) $identity}
 if($Validated){$events+=Event 'PC_FRAME_VALIDATED' $events.Count 'PC_TICKS' '12000000' ([pscustomobject]@{received_bytes=21;crc_valid=$true;complete_frame=$true;frame_sha256=('A'*64)}) $identity}
 [pscustomobject]@{schema='vc-lora-r19-timed-path-evidence-v1';identity=$identity;clock_correlation=$null;trace_complete=$true;trace_overflow=$false;events=@($events)}
}
function Correlation($Binding) {
 $id=[pscustomobject]@{role=$Binding.role;candidate_id=$Binding.candidate_id;session_id=$Binding.reader_session;boot_instance=@($Binding.boot_instance)}
 [pscustomobject]@{binding=(Clone $Binding);evidence_sha256=('C'*64);observation=[pscustomobject]@{
  schema='vc-lora-r19-usb-clock-correlation-observation-v1';identity=(Clone $id)
  failure=[pscustomobject]@{role=$id.role;candidate_id=$id.candidate_id;session_id=$id.session_id;boot_instance=@($id.boot_instance);device_us='1106638';quantization_us='0'}
  sync=[pscustomobject]@{role=$id.role;candidate_id=$id.candidate_id;session_id=$id.session_id;boot_instance=@($id.boot_instance)
   nonce=$Binding.nonce;echoed_nonce=$Binding.nonce;device_us='1000000';quantization_us='0'}
  pc=[pscustomobject]@{clock_domain_id='qpc-trace';open_clock_domain_id='qpc-trace';sync_clock_domain_id='qpc-trace';frequency='1000000'
   open_before_ticks='8000000';open_after_ticks='8000100';send_before_ticks='10000000';receive_after_ticks='10001000';read_loop_armed_ticks='9000000'}
  continuity=[pscustomobject]@{same_boot=$true;reset_absent=$true;sleep_absent=$true;halt_absent=$true;clock_reinitialization_absent=$true}
  error_bound=[pscustomobject]@{guaranteed=$true;rate_error_ppb='0';additive_us='0';source='synthetic exact bound; not a measured hardware guarantee'}
 }}
}
function Reindex($Evidence){for($i=0;$i-lt$Evidence.events.Count;$i++){$Evidence.events[$i].ordinal=$i}}
function Apply-Identity($Evidence,$Identity){$Evidence.identity=Clone $Identity;foreach($ev in $Evidence.events){$ev.identity=Clone $Identity}}

Check (Test-Path -LiteralPath $tool) 'tool_exists'
. $tool -ImportOnly
$e=Fixture;$e.events=@();$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'NO_TRACE_EVIDENCE') 'empty_trace_is_unknown_not_healthy'
Check (-not$r.pc_frame_validated-and-not$r.local_usb_completed) 'no_event_is_not_completion'
Check ($r.rf_status-ceq'NOT_EVALUATED'-and$r.parameters_status-ceq'NOT_EVALUATED') 'empty_trace_has_no_rf_or_parameter_coverage'
$e.identity=$null;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'NO_TRACE_EVIDENCE'-and-not$r.pc_frame_validated-and-not$r.local_usb_completed) 'missing_frame_identity_allowed_only_for_actual_empty_evidence'
$e.trace_complete=$false;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'TRACE_INCOMPLETE') 'null_identity_does_not_hide_incomplete_coverage'
$e=Fixture;$e.identity=$null;Reject $e 'nonempty_events_require_identity'
$e=Fixture;$e.clock_correlation=Correlation $e.identity;$e.events=@();$e.identity=$null;Reject $e 'clock_observation_cannot_float_without_identity'

$e=Fixture;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'PARTIAL_TRACE') 'pickup_only_is_partial'
Check ($r.last_observed_mcu_stage-ceq'MCU_USB_PICKUP_OBSERVED') 'last_observed_boundary_is_pickup_not_invented_completion'
Check (-not$r.pc_frame_validated-and-not$r.local_usb_completed-and-not$r.clock_bounds_valid) 'pickup_is_not_usb_completion_or_pc_crc'
Check ($r.missing_stages-contains'PC_FRAME_VALIDATED') 'unseen_pc_stage_is_missing_not_failure'
Check (@($r.mcu_deltas).Count-eq4-and$r.mcu_deltas[0].elapsed_us-ceq'100') 'same_mcu_clock_deltas_without_pc_offset'
Check ($r.mcu_deltas[0].from-ceq'MCU_ARM_ACCEPTED'-and$r.mcu_deltas[0].to-ceq'MCU_FRAME_ENQUEUED') 'mcu_delta_names_are_observed_adjacent_events'
Check (@($r.event_timeline|Where-Object{$null-ne$_.pc_bounds-and$_.pc_bounds.bounds_valid}).Count-eq0) 'no_clock_estimate_from_bare_timestamps'
Check (-not$r.physical_fifo_fault_proven-and-not$r.kernel_pending_read_proven-and-not$r.root_cause_proven) 'ring_stash_zero_and_pickup_gap_do_not_prove_physical_fault'
Check (-not$r.hardware_interaction-and-not$r.acceptance_eligible-and-not$r.deployment_authorized) 'offline_trace_never_authorizes_hardware_or_acceptance'
$published=@($r.event_timeline|Where-Object{$_.kind-ceq'MCU_USB_PUBLISHED'})[0]
Check ($null-ne$published.PSObject.Properties['details']-and$null-ne$published.PSObject.Properties['evidence_sha256']-and$published.details.publish_generation-eq3-and$published.evidence_sha256-ceq('B'*64)) 'timeline_retains_validated_monitor_values_and_source_evidence_hash'
$e.events[4].details.publish_generation=99
Check ($published.details.publish_generation-eq3) 'timeline_monitor_snapshot_is_deep_copied_not_mutable_input_alias'

$e=Fixture -Failed;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM') 'failure_after_arm_from_same_mcu_clock'
Check ($r.failure_elapsed_us-ceq'106238') '106ms_contract_and_actual_106238us_failure_interval_remain_distinct'
Check ($r.mcu_deltas[-1].elapsed_us-ceq'106338') 'adjacent_stage_delta_not_relabelled_transaction_duration'
Check (-not$r.clock_bounds_valid-and-not$r.root_cause_proven) 'after_arm_is_not_pc_order_or_root_cause'
Check ($r.rf_status-ceq'NOT_EVALUATED'-and$r.parameters_status-ceq'NOT_EVALUATED') 'usb_timeout_does_not_fail_unmeasured_layers'
$e.events[1].timestamp='1200000';$e.events=@($e.events[0],$e.events[2],$e.events[3],$e.events[4],$e.events[5],$e.events[6],$e.events[1]);Reindex $e
$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_BEFORE_DEVICE_ARM') 'failure_before_arm_is_gate_or_binding_review_not_readiness_root_cause'
$e=Fixture -Failed;$e.events[1].timestamp='1050000';$e.events=@($e.events[0],$e.events[2],$e.events[3],$e.events[4],$e.events[5],$e.events[1],$e.events[6]);Reindex $e
$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_OVERLAPS_DEVICE_ARM') 'arm_inside_failed_transaction_remains_ambiguous'
$e=Fixture -Failed;$e.events[1].details.device_clock_continuity_verified=$false;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_ORDER_UNKNOWN') 'unproven_mcu_clock_continuity_cannot_order_arm'
Check (@($r.mcu_deltas).Count-eq0) 'unproven_mcu_clock_continuity_cannot_promote_elapsed_deltas'
$e=Fixture -Failed;$e.events=@($e.events|Where-Object{$_.kind-cne'MCU_ARM_ACCEPTED'});Reindex $e;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_ORDER_UNKNOWN') 'missing_arm_does_not_infer_pre_arm_failure'

$e=Fixture -Completed;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'LOCAL_USB_COMPLETION_OBSERVED'-and$r.local_usb_completed-and-not$r.pc_frame_validated) 'local_completion_is_not_pc_receipt'
$e=Fixture -Completed -Validated;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'PC_FRAME_VALIDATED_OBSERVED'-and$r.local_usb_completed-and$r.pc_frame_validated) 'bound_complete_pc_crc_is_separate_observation'
Check ($r.rf_status-ceq'NOT_EVALUATED'-and$r.parameters_status-ceq'NOT_EVALUATED'-and-not$r.acceptance_eligible) 'pc_usb_frame_is_not_rf_or_932_parameter_pass'
$e=Fixture -Failed -Validated;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM'-and$r.pc_frame_validated) 'later_validated_frame_does_not_erase_recorded_completion_failure'
foreach($field in @('trace_complete','trace_overflow')){
 $e=Fixture -Completed -Validated;$e.$field=($field-ceq'trace_overflow');$r=Get-R19TimedPathTraceEvaluation -Evidence $e
 Check ($r.classification-ceq'TRACE_INCOMPLETE'-and-not$r.acceptance_eligible) "incomplete_or_overflow_${field}_is_fail_closed"
}

$e=Fixture -Failed;$e.clock_correlation=Correlation $e.identity;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.clock_bounds_valid) 'independently_bounded_clock_observation_can_map_mcu_events'
$mapped=@($r.event_timeline|Where-Object{$_.kind-ceq'MCU_USB_FAILED'})[0]
Check ($mapped.pc_bounds.lower_pc_us-ceq'10106638'-and$mapped.pc_bounds.upper_pc_us-ceq'10107638'-and$mapped.pc_bounds.interval_width_us-ceq'1000') 'exact_outward_pc_bounds_not_midpoint_guess'
Check ($mapped.pc_bounds.read_relation-ceq'POST_READ_LOOP_ARMED') 'failure_interval_strictly_after_application_read_boundary'
Check (-not$r.kernel_pending_read_proven) 'read_boundary_mapping_is_not_kernel_pending_read_proof'
$e.events[0].timestamp='10000500';$e.clock_correlation.observation.pc.read_loop_armed_ticks='10000500';$r=Get-R19TimedPathTraceEvaluation -Evidence $e
$mapped=@($r.event_timeline|Where-Object{$_.kind-ceq'MCU_ARM_ACCEPTED'})[0]
Check ($mapped.pc_bounds.bounds_valid-and$mapped.pc_bounds.read_relation-ceq'UNKNOWN') 'read_boundary_inside_error_interval_is_unknown'
$e=Fixture -Failed;$e.clock_correlation=Correlation $e.identity;$e.clock_correlation.observation.error_bound.guaranteed=$false;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check (-not$r.clock_bounds_valid-and$r.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM') 'unreviewed_error_bound_blocks_pc_mapping_not_same_clock_order'
$e=Fixture -Failed;$e.clock_correlation=Correlation $e.identity;$e.clock_correlation.observation.continuity.halt_absent=$false;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check (-not$r.clock_bounds_valid) 'intervening_halt_prevents_clock_mapping'
$e=Fixture -Completed -Validated;$e.clock_correlation=Correlation $e.identity;$e.events[-1].timestamp='9000001'
Reject $e 'pc_validation_strictly_before_guaranteed_enqueue_lower_bound_is_causal_contradiction'
foreach($pcTicks in @('10000100','10000500')){
 $e=Fixture -Completed -Validated;$e.clock_correlation=Correlation $e.identity;$e.events[-1].timestamp=$pcTicks;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
 Check ($r.classification-ceq'PC_FRAME_VALIDATED_OBSERVED'-and$r.pc_frame_validated) "pc_validation_equal_or_inside_enqueue_uncertainty_${pcTicks}_not_rejected"
}
$e=Fixture -Completed -Validated;$e.clock_correlation=Correlation $e.identity;$e.events[-1].timestamp='10000200';$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.pc_frame_validated-and$r.local_usb_completed) 'pc_receipt_may_precede_local_flush_completion_confirmation'

foreach($case in @('root-schema','root-extra','role','candidate-empty','zero-boot','boot-width','build-width','epoch-width','zero-session','session-overflow','private-nonce','empty-frame-id','invalid-frame-hash','unknown-frame-kind','frame-length-zero','frame-length-overflow','heartbeat-too-short','string-bool','unknown-kind','wrong-domain','float-timestamp','leading-zero-time','negative-time','timestamp-overflow','noncontiguous-ordinal','backward-mcu','backward-pc','wrong-boot','wrong-build','wrong-epoch','wrong-session','wrong-nonce','wrong-frame','wrong-frame-hash','mixed-diag-frame','event-extra','detail-extra','missing-detail','invalid-evidence-hash','budget-changed','failure-start-after-finish','failure-timestamp-mismatch','failure-start-before-enqueue','failure-accepted-mismatch','overaccept','negative-accept','fractional-accept','enqueue-size','completion-size','completion-accepted-mismatch','completion-before-enqueue','pc-size','pc-crc-false','pc-incomplete','pc-frame-hash','zero-frequency','duplicate-terminal','duplicate-kind')){
 $e=Fixture -Failed
 switch($case){
  'root-schema'{$e.schema='wrong'}
  'root-extra'{$e|Add-Member NoteProperty invented_health $true}
  'role'{$e.identity.role='vehicle'}
  'candidate-empty'{$e.identity.candidate_id=''}
  'zero-boot'{$e.identity.boot_instance=@(0,0,0,0)}
  'boot-width'{$e.identity.boot_instance[0]='4294967296'}
  'build-width'{$e.identity.build_fingerprint[0]='4294967296'}
  'epoch-width'{$e.identity.usb_epoch='4294967296'}
  'zero-session'{$e.identity.reader_session='0'}
  'session-overflow'{$e.identity.reader_session='18446744073709551616'}
  'private-nonce'{$e.identity.nonce='1'}
  'empty-frame-id'{$e.identity.frame_id=''}
  'invalid-frame-hash'{$e.identity.frame_sha256='missing'}
  'unknown-frame-kind'{$e.identity.frame_kind='ANY'}
  'frame-length-zero'{$e.identity.expected_frame_bytes=0}
  'frame-length-overflow'{$e.identity.expected_frame_bytes=281}
  'heartbeat-too-short'{$e.identity.expected_frame_bytes=20}
  'string-bool'{$e.trace_complete='true'}
  'unknown-kind'{$e.events[1].kind='MCU_EVERYTHING_OK'}
  'wrong-domain'{$e.events[1].domain='PC_TICKS'}
  'float-timestamp'{$e.events[1].timestamp=1000000.5}
  'leading-zero-time'{$e.events[1].timestamp='01000000'}
  'negative-time'{$e.events[1].timestamp='-1'}
  'timestamp-overflow'{$e.events[1].timestamp='18446744073709551616'}
  'noncontiguous-ordinal'{$e.events[2].ordinal=7}
  'backward-mcu'{$e.events[2].timestamp='999999'}
  'backward-pc'{$e=Fixture -Failed -Validated;$e.events[-1].timestamp='8999999'}
  'wrong-boot'{$e.events[2].identity.boot_instance[0]=99}
  'wrong-build'{$e.events[2].identity.build_fingerprint[0]=99}
  'wrong-epoch'{$e.events[2].identity.usb_epoch=2}
  'wrong-session'{$e.events[2].identity.reader_session='124'}
  'wrong-nonce'{$e.events[2].identity.nonce='5915759585527857154'}
  'wrong-frame'{$e.events[2].identity.frame_id='different-frame'}
  'wrong-frame-hash'{$e.events[2].identity.frame_sha256=('D'*64)}
  'mixed-diag-frame'{$e.events[2].identity.frame_kind='DIAGNOSTIC';$e.events[2].identity.expected_frame_bytes=63}
  'event-extra'{$e.events[2]|Add-Member NoteProperty guessed_physical_location 'endpoint'}
  'detail-extra'{$e.events[2].details|Add-Member NoteProperty assumed_completed $true}
  'missing-detail'{$e.events[2].details=[pscustomobject]@{}}
  'invalid-evidence-hash'{$e.events[2].evidence_sha256='unknown'}
  'budget-changed'{$e.events[-1].details.budget_ms=107}
  'failure-start-after-finish'{$e.events[-1].details.started_us='1106639'}
  'failure-timestamp-mismatch'{$e.events[-1].details.finished_us='1106637'}
  'failure-start-before-enqueue'{$e.events[-1].details.started_us='1000099'}
  'failure-accepted-mismatch'{$e.events[-1].details.accepted_bytes=20}
  'overaccept'{$e.events[3].details.accepted_bytes=22}
  'negative-accept'{$e.events[3].details.accepted_bytes=-1}
  'fractional-accept'{$e.events[3].details.accepted_bytes=20.5}
  'enqueue-size'{$e.events[2].details.frame_bytes=20}
  'completion-size'{$e=Fixture -Completed;$e.events[-1].details.completed_bytes=20}
  'completion-accepted-mismatch'{$e=Fixture -Completed;$e.events[3].details.accepted_bytes=0}
  'completion-before-enqueue'{$e=Fixture -Completed;$e.events[2].timestamp='1000500';$e.events=@($e.events[0],$e.events[1],$e.events[3],$e.events[4],$e.events[5],$e.events[6],$e.events[2]);Reindex $e}
  'pc-size'{$e=Fixture -Validated;$e.events[-1].details.received_bytes=20}
  'pc-crc-false'{$e=Fixture -Validated;$e.events[-1].details.crc_valid=$false}
  'pc-incomplete'{$e=Fixture -Validated;$e.events[-1].details.complete_frame=$false}
  'pc-frame-hash'{$e=Fixture -Validated;$e.events[-1].details.frame_sha256=('D'*64)}
  'zero-frequency'{$e.events[0].details.frequency='0'}
  'duplicate-terminal'{$e.events+=Event 'MCU_USB_COMPLETED' $e.events.Count 'MCU_US' '1106700' ([pscustomobject]@{completed_bytes=21}) $e.identity}
  'duplicate-kind'{$e.events+=Event 'MCU_USB_FAILED' $e.events.Count 'MCU_US' '1106638' (Clone $e.events[-1].details) $e.identity}
 }
 Reject $e "reject_$case"
}
foreach($case in @('binding-boot','binding-frame','raw-boot','raw-candidate','raw-session','raw-nonce','pc-clock-domain','pc-frequency','pc-read-boundary','wrapper-extra')){
 $e=Fixture -Failed;$e.clock_correlation=Correlation $e.identity
 switch($case){
  'binding-boot'{$e.clock_correlation.binding.boot_instance[0]=99}
  'binding-frame'{$e.clock_correlation.binding.frame_id='other-frame'}
  'raw-boot'{$e.clock_correlation.observation.sync.boot_instance[0]=99}
  'raw-candidate'{$e.clock_correlation.observation.identity.candidate_id='other-candidate'}
  'raw-session'{$e.clock_correlation.observation.identity.session_id='124'}
  'raw-nonce'{$e.clock_correlation.observation.sync.nonce='5915759585527857154'}
  'pc-clock-domain'{$e.events[0].details.clock_domain_id='other-qpc'}
  'pc-frequency'{$e.events[0].details.frequency='10000000'}
  'pc-read-boundary'{$e.clock_correlation.observation.pc.read_loop_armed_ticks='9000001'}
  'wrapper-extra'{$e.clock_correlation|Add-Member NoteProperty trusted_without_evidence $true}
 }
 Reject $e "reject_correlation_$case"
}

$e=Fixture -Completed -Validated;$diagnostic=Identity;$diagnostic.frame_kind='DIAGNOSTIC';$diagnostic.expected_frame_bytes=63;$diagnostic.frame_id='diagnostic-r19f-0001';$diagnostic.frame_sha256=('D'*64);Apply-Identity $e $diagnostic
$e.events[2].details.frame_bytes=63;$e.events[3].details.accepted_bytes=63;$e.events[-2].details.completed_bytes=63;$e.events[-1].details.received_bytes=63;$e.events[-1].details.frame_sha256=('D'*64)
$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.pc_frame_validated-and$r.classification-ceq'PC_FRAME_VALIDATED_OBSERVED') 'separate_63byte_diagnostic_transaction_is_valid_without_becoming_heartbeat'
Check ($r.rf_status-ceq'NOT_EVALUATED'-and$r.parameters_status-ceq'NOT_EVALUATED') 'diagnostic_success_does_not_promote_product_link'
foreach($diagnosticBudget in @(106,500)){
 $e=Fixture -Failed;Apply-Identity $e $diagnostic
 $e.events[2].details.frame_bytes=63;$e.events[3].details.accepted_bytes=63;$e.events[-1].details.accepted_bytes=63;$e.events[-1].details.budget_ms=$diagnosticBudget
 Reject $e "diagnostic_failure_${diagnosticBudget}ms_is_not_product_106ms_contract"
}
$e=Fixture -Failed;$e.events[0].timestamp='18446744073709551615';$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM') 'cross_domain_magnitude_not_used_as_execution_order'
$e=Fixture -Failed;$e.events[3].details.accepted_bytes=0;$e.events[-1].details.accepted_bytes=0;$r=Get-R19TimedPathTraceEvaluation -Evidence $e
Check ($r.classification-ceq'USB_FAILURE_AFTER_DEVICE_ARM') 'zero_accepted_bytes_remains_observed_failure_not_malformed_success'

$source=[IO.File]::ReadAllText($tool)
Check ($source-notmatch'(?i)SerialPort|Get-PnpDevice|Get-CimInstance|Start-Process|Invoke-RestMethod|Invoke-WebRequest|taskkill') 'pure_offline_no_hardware_process_or_network_entrypoint'
Write-Output "TIMED_PATH_TRACE_EVALUATION PASS $script:checks checks"
if($EvidenceDirectory){
 [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
 [pscustomobject]@{schema='vc-lora-r19-timed-path-trace-tests-v1';result='PASS';checks=$script:checks;hardware_interaction=$false;acceptance_eligible=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'test_summary.json') -Encoding utf8
}
