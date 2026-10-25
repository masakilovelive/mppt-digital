# OFFLINE, opt-in diagnostic state machine. Import codecs explicitly before use:
#   . tools/r19_host_readiness_wire.ps1
#   . tools/r19_usb_clock_correlation.ps1
# No COM, I/O, clock sampling, process, random nonce generation or live entrypoint.
# Caller supplies complete frames and exact monotonic samples from one PC clock
# domain; these application claims cannot prove a kernel-pending Read or a host
# USB IN transaction. Existing sealed candidates do not implement this workflow.
# ARM is private USB startup admission, NOT Pixhawk flight arming/authentication.

function Stop-R19HostReadinessWorkflow {
  param([object]$State,[string]$Reason)
  if($null-ne$State-and$State.status-cne'Rejected'){
    $State.status='Rejected';$State.failure_reason=$Reason
    $State.events.Add([pscustomobject][ordered]@{ordinal=$State.events.Count;kind='Rejected';pc_ticks=$State.last_ticks;reason=$Reason})
  }
  throw $Reason
}

function Add-R19HostReadinessWorkflowEvent {
  param([object]$State,[string]$Kind)
  $State.events.Add([pscustomobject][ordered]@{ordinal=$State.events.Count;kind=$Kind;pc_ticks=$State.last_ticks;reason=''})
}

function New-R19HostReadinessWorkflow {
  param(
    [Parameter(Mandatory)][ValidateSet('SyncOnly','ExplicitHostArm')][string]$Mode,
    [Parameter(Mandatory)][ValidateSet('Ground','Vehicle')][string]$Role,
    [Parameter(Mandatory)][object]$Nonce,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReaderIdentity,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClockDomainId,
    [Parameter(Mandatory)][object]$TickFrequency,
    [Parameter(Mandatory)][object]$StartTicks,
    [Parameter(Mandatory)][object]$ReadStartedTicks,
    [Parameter(Mandatory)][object]$TimeoutTicks,
    [object]$ExpectedBinding=$null
  )
  [uint64]$nonceValue=ConvertTo-R19HostReadinessUInt $Nonce 'nonce'
  if(-not(Test-R19HostReadinessNonce $nonceValue)){throw 'Nonce must be fresh in the private 0x5219 domain'}
  if($Mode-ieq'ExplicitHostArm'-and$Role-ine'Ground'){throw 'ExplicitHostArm is Ground USB product admission only'}
  $frequency=ConvertTo-R19HostReadinessUInt $TickFrequency 'tick_frequency'
  $start=Get-R19ClockInteger $StartTicks 'start_ticks'
  $read=Get-R19ClockInteger $ReadStartedTicks 'read_started_ticks'
  $timeout=Get-R19ClockInteger $TimeoutTicks 'timeout_ticks'
  $limit=Get-R19ClockInteger '18446744073709551615' 'limit'
  if($read-gt$start-or$timeout-eq0-or$start+$timeout-gt$limit){throw 'Reader must already be started and acquisition deadline must be positive and representable'}
  $expected=$null
  if($null-ne$ExpectedBinding){
    if($ExpectedBinding.role-ine$Role){throw 'Expected device role mismatch'}
    $expected=[pscustomobject][ordered]@{role=$Role
      boot_id=[string](ConvertTo-R19HostReadinessUInt $ExpectedBinding.boot_id 'boot_id')
      reader_session=[string](ConvertTo-R19HostReadinessUInt $ExpectedBinding.reader_session 'reader_session')
      usb_epoch=[string](ConvertTo-R19HostReadinessUInt $ExpectedBinding.usb_epoch 'usb_epoch' 4294967295 -AllowZero)}
  }
  $state=[pscustomobject][ordered]@{
    schema='vc-lora-r19-host-readiness-workflow-v1';mode=$Mode;role=$Role;status='WaitingClockRequest'
    nonce=[string]$nonceValue;reader_identity=$ReaderIdentity;clock_domain_id=$ClockDomainId;tick_frequency=[string]$frequency
    start_ticks=[string]$start;read_started_ticks=[string]$read;last_ticks=[string]$start;deadline_ticks=[string]($start+$timeout)
    deadline_origin='PC_workflow_start_NOT_device_setup';device_setup_deadline_known=$false
    expected_binding=$expected;binding_authority=$(if($Mode-ieq'SyncOnly'){'unavailable_in_SyncOnly_clock_reply'}elseif($null-ne$expected){'caller_supplied_expected_tuple'}else{'first_nonce_matched_READY_assertion'})
    ready_required=($Mode-ieq'ExplicitHostArm');ready_binding_validated=$false
    clock_request_built=$false;clock_request_built_ticks='';clock_request_write_accepted=$false
    clock_request_write_started_ticks='';clock_request_write_accepted_ticks=''
    reply=$null;reply_read_validated=$false;reply_read_completed_ticks='';ready=$null;ready_read_completed_ticks=''
    arm_built=$false;arm_built_ticks='';arm_write_accepted=$false;arm_write_started_ticks='';arm_write_accepted_ticks=''
    device_armed_proven=$false;kernel_pending_read_proven=$false;clock_relation='UNKNOWN_NO_OFFSET_BOUNDS'
    hardware_interaction=$false;live_integration_ready=$false;product_acceptance=$false;failure_reason=''
    events=[Collections.Generic.List[object]]::new()
  }
  Add-R19HostReadinessWorkflowEvent $state 'Begin'
  return $state
}

function Update-R19HostReadinessWorkflow {
  param([Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][object]$NowTicks,
    [Parameter(Mandatory)][string]$ReaderIdentity,
    [Parameter(Mandatory)][bool]$ReaderAlive,
    [Parameter(Mandatory)][string]$ClockDomainId)
  if($State.schema-cne'vc-lora-r19-host-readiness-workflow-v1'-or$State.status-ceq'Rejected'){throw 'Workflow is invalid or already rejected'}
  try{$now=Get-R19ClockInteger $NowTicks 'now_ticks'}catch{Stop-R19HostReadinessWorkflow $State 'InvalidMonotonicSample'}
  if($ClockDomainId-cne$State.clock_domain_id){Stop-R19HostReadinessWorkflow $State 'ClockDomainChanged'}
  if(-not$ReaderAlive){Stop-R19HostReadinessWorkflow $State 'ContinuousReaderStopped'}
  if($ReaderIdentity-cne$State.reader_identity){Stop-R19HostReadinessWorkflow $State 'ContinuousReaderReplaced'}
  if($now-lt(Get-R19ClockInteger $State.last_ticks 'last_ticks')){Stop-R19HostReadinessWorkflow $State 'MonotonicClockRegressed'}
  $State.last_ticks=[string]$now
  # Once local ARM OUT acceptance is recorded this timer has achieved its
  # *PC-local* purpose; it still does not imply the MCU's setup deadline passed.
  if($State.status-cne'ArmWriteAcceptedAwaitingDeviceEvidence'-and$State.status-cne'SyncOnlyClockReplyValidated'-and
     $now-gt(Get-R19ClockInteger $State.deadline_ticks 'deadline_ticks')){Stop-R19HostReadinessWorkflow $State 'PcAcquisitionDeadlineExpired'}
}

function New-R19HostReadinessClockRequest {
  param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][object]$NowTicks,
    [Parameter(Mandatory)][string]$ReaderIdentity,[Parameter(Mandatory)][bool]$ReaderAlive,
    [Parameter(Mandatory)][string]$ClockDomainId,[byte]$Sequence=0)
  Update-R19HostReadinessWorkflow -State $State -NowTicks $NowTicks -ReaderIdentity $ReaderIdentity -ReaderAlive $ReaderAlive -ClockDomainId $ClockDomainId
  if($State.status-cne'WaitingClockRequest'-or$State.clock_request_built){Stop-R19HostReadinessWorkflow $State 'ClockRequestReplayOrOutOfOrder'}
  [byte[]]$bytes=New-R19TimesyncRequest -Nonce ([long]$State.nonce) -Sequence $Sequence
  $State.clock_request_built=$true;$State.clock_request_built_ticks=$State.last_ticks;$State.status='ClockRequestBuilt'
  Add-R19HostReadinessWorkflowEvent $State 'ClockRequestBuilt'
  return ,$bytes
}

function Set-R19HostReadinessWriteCommit {
  param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][ValidateSet('ClockRequest','Arm')][string]$Kind,
    [Parameter(Mandatory)][object]$AcceptedBytes,[Parameter(Mandatory)][object]$WriteStartedTicks,
    [Parameter(Mandatory)][object]$NowTicks,[Parameter(Mandatory)][string]$ReaderIdentity,
    [Parameter(Mandatory)][bool]$ReaderAlive,[Parameter(Mandatory)][string]$ClockDomainId)
  Update-R19HostReadinessWorkflow -State $State -NowTicks $NowTicks -ReaderIdentity $ReaderIdentity -ReaderAlive $ReaderAlive -ClockDomainId $ClockDomainId
  $isClock=$Kind-ieq'ClockRequest';$requiredStatus=if($isClock){'ClockRequestBuilt'}else{'ArmBuilt'}
  if($State.status-cne$requiredStatus){Stop-R19HostReadinessWorkflow $State 'WriteCommitReplayOrOutOfOrder'}
  try{$count=Get-R19ClockInteger $AcceptedBytes 'accepted_bytes';$begin=Get-R19ClockInteger $WriteStartedTicks 'write_started_ticks'}catch{Stop-R19HostReadinessWorkflow $State 'InvalidWriteSample'}
  $built=if($isClock){$State.clock_request_built_ticks}else{$State.arm_built_ticks}
  if($begin-lt(Get-R19ClockInteger $built 'built_ticks')-or$begin-gt(Get-R19ClockInteger $State.last_ticks 'write_return_ticks')){Stop-R19HostReadinessWorkflow $State 'WriteSampleOrderInvalid'}
  $length=if($isClock){28}else{66}
  if($count-ne$length){Stop-R19HostReadinessWorkflow $State 'PartialOrOversizedWriteAcceptance'}
  if($isClock){
    $State.clock_request_write_accepted=$true;$State.clock_request_write_started_ticks=[string]$begin
    $State.clock_request_write_accepted_ticks=$State.last_ticks;$State.status='WaitingClockReply'
    Add-R19HostReadinessWorkflowEvent $State 'ClockRequestWriteAccepted'
  }else{
    $State.arm_write_accepted=$true;$State.arm_write_started_ticks=[string]$begin
    $State.arm_write_accepted_ticks=$State.last_ticks;$State.status='ArmWriteAcceptedAwaitingDeviceEvidence'
    Add-R19HostReadinessWorkflowEvent $State 'ArmWriteAccepted'
  }
}

function Add-R19HostReadinessObservation {
  param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][ValidateSet('ClockReply','Ready')][string]$Kind,
    [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,[Parameter(Mandatory)][object]$ReadCompletedTicks,
    [Parameter(Mandatory)][object]$NowTicks,[Parameter(Mandatory)][string]$ReaderIdentity,
    [Parameter(Mandatory)][bool]$ReaderAlive,[Parameter(Mandatory)][string]$ClockDomainId)
  Update-R19HostReadinessWorkflow -State $State -NowTicks $NowTicks -ReaderIdentity $ReaderIdentity -ReaderAlive $ReaderAlive -ClockDomainId $ClockDomainId
  # Actual bridge mode 1 publishes only the 28-byte clock reply. The binding
  # READY envelope exists only in mode 2; never wait for it in the control run.
  if($Kind-ieq'Ready'-and$State.mode-ieq'SyncOnly'){Stop-R19HostReadinessWorkflow $State 'ReadyNotEmittedBySyncOnly'}
  $isReply=$Kind-ieq'ClockReply';$requiredStatus=if($isReply){'WaitingClockReply'}else{'WaitingReady'}
  if($State.status-cne$requiredStatus){Stop-R19HostReadinessWorkflow $State 'ObservationReplayOrOutOfOrder'}
  try{$read=Get-R19ClockInteger $ReadCompletedTicks 'read_completed_ticks'}catch{Stop-R19HostReadinessWorkflow $State 'InvalidReadReturnSample'}
  # Read on the continuing thread may return during the concurrent OUT call;
  # therefore the lower bound is the OUT begin, NOT its return/acceptance sample.
  $lower=if($isReply){$State.clock_request_write_started_ticks}else{$State.reply_read_completed_ticks}
  if($read-lt(Get-R19ClockInteger $lower 'read_lower_bound')-or$read-gt(Get-R19ClockInteger $State.last_ticks 'observation_ticks')){Stop-R19HostReadinessWorkflow $State 'ReadReturnSampleOrderInvalid'}
  if($isReply){
    $reply=ConvertFrom-R19TimesyncResponse -Bytes $Bytes -ExpectedNonce ([long]$State.nonce)
    if(-not$reply.valid){Stop-R19HostReadinessWorkflow $State 'InvalidClockReplyFrame'}
    $State.reply=$reply;$State.reply_read_validated=$true;$State.reply_read_completed_ticks=[string]$read
    $State.status=if($State.mode-ieq'SyncOnly'){'SyncOnlyClockReplyValidated'}else{'WaitingReady'}
    Add-R19HostReadinessWorkflowEvent $State 'ClockReplyReadValidated'
  }else{
    $ready=ConvertFrom-R19HostReadinessFrame -Bytes $Bytes
    if(-not$ready.valid-or$ready.opcode-cne'Ready'-or$ready.role-ine$State.role-or
       $ready.nonce-cne$State.nonce-or$ready.reply_device_us-cne$State.reply.device_microseconds){Stop-R19HostReadinessWorkflow $State 'InvalidOrUnboundReadyFrame'}
    if($null-ne$State.expected_binding){
      foreach($field in @('role','boot_id','reader_session','usb_epoch')){
        if([string]$ready.$field-ine[string]$State.expected_binding.$field){Stop-R19HostReadinessWorkflow $State ('ReadyExpectedBindingMismatch_'+$field)}
      }
    }
    $State.ready=$ready;$State.ready_read_completed_ticks=[string]$read;$State.ready_binding_validated=$true
    $State.status='ReadyValidated'
    Add-R19HostReadinessWorkflowEvent $State 'ReadyReadValidated'
  }
}

function New-R19HostReadinessWorkflowArm {
  param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][object]$NowTicks,
    [Parameter(Mandatory)][string]$ReaderIdentity,[Parameter(Mandatory)][bool]$ReaderAlive,
    [Parameter(Mandatory)][string]$ClockDomainId,[byte]$Sequence=0)
  Update-R19HostReadinessWorkflow -State $State -NowTicks $NowTicks -ReaderIdentity $ReaderIdentity -ReaderAlive $ReaderAlive -ClockDomainId $ClockDomainId
  if($State.mode-ine'ExplicitHostArm'-or$State.role-ine'Ground'){Stop-R19HostReadinessWorkflow $State 'ArmNotPermittedInThisControlMode'}
  if($State.status-cne'ReadyValidated'-or$State.arm_built-or-not$State.reply_read_validated){Stop-R19HostReadinessWorkflow $State 'ArmReplayOrMissingValidatedReplyAndReady'}
  [byte[]]$bytes=New-R19HostReadinessArm -Ready $State.ready -ReplyReadValidated $true -ContinuousReader $true -Sequence $Sequence
  $State.arm_built=$true;$State.arm_built_ticks=$State.last_ticks;$State.status='ArmBuilt'
  Add-R19HostReadinessWorkflowEvent $State 'ArmBuilt'
  return ,$bytes
}
