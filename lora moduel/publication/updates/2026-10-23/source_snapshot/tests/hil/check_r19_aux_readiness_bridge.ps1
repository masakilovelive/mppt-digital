param([string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:n=0
function Check($v,$name){if(-not$v){throw "FAIL $name"};$script:n++}
$source=Get-Content -LiteralPath (Join-Path $RepoRoot 'firmware/phase6/vc_lora_phase6_bridge.hpp') -Raw
foreach($term in @('#define VC_LORA_R19_AUX_READINESS_DIAGNOSTICS 0',
    'R19 AUX/readiness diagnostics require timed-path ExplicitHostArm diagnostics',
    'high_speed/r19_aux_readiness_record.hpp','vc_lora_r19_aux_readiness_record',
    'void IRAM_ATTR r19_aux_readiness_irq','gpio_ll_get_level',
    'gpio_install_isr_service','gpio_isr_handler_add','GPIO_INTR_ANYEDGE',
    '.aux.observe_gpio(','.aux.observe_uart(','.aux.observe_state(','.aux.latch_fault(',
    '.edges.observe_edge(','.ready.interval(',
    'ClockFlushBegin','ClockFlushEnd','GateUpdate','ReadyEncode',
    'ReadyPublishBegin','ReadyPublishEnd','ArmReceived','ArmAccepted','IrqAttach','ClockFlushContext')){
  Check ($source.Contains($term)) "bridge hook $term"
}
Check (([regex]::Matches($source,'r19_observe_e220_aux\(now_ms\);')).Count-eq4) 'all four E220 contract sampling sites wrapped'
Check (([regex]::Matches($source,'r19_note_e220_uart_acceptance\(write_begin_us,')).Count-eq2) 'both UART acceptance paths instrumented'
Check (([regex]::Matches($source,'e220_write_contract\.observe_aux\(aux_high\(now_ms\), now_ms\)')).Count-eq1) 'sole E220 sampling implementation records exact supplied clock'
Check (([regex]::Matches($source,'aux_high\(accepted_at_ms\)')).Count-eq2) 'both UART results record exact supplied acceptance milliseconds'
$gpio=[regex]::Match($source,'(?s)bool aux_high\(std::uint64_t supplied_now_ms\).*?\n\}')
Check $gpio.Success 'diagnostic contract GPIO overload found'
Check ($gpio.Value-match '(?s)begin_us.*?digitalRead\(kE220AuxPin\).*?end_us.*?\.aux\.observe_gpio\(begin_us, end_us,\s*supplied_now_ms') 'GPIO bracket and untruncated exact contract milliseconds'
Check ($source.Contains('bool aux_high() noexcept { return digitalRead(kE220AuxPin) == HIGH; }')) 'incidental reads excluded from contract observer cadence'
$irq=[regex]::Match($source,'(?s)void IRAM_ATTR r19_aux_readiness_irq\([^)]*\).*?\n\}')
Check $irq.Success 'ISR body found'
Check ($irq.Value.Contains('esp_timer_get_time()')-and$irq.Value.Contains('.edges.observe_edge(')) 'ISR same MCU clock and independent record'
Check (-not($irq.Value-match 'Serial\.|digitalRead\(|malloc|new |\.aux\.|\.ready\.|try_snapshot|mutex|lock_guard')) 'ISR no main record, Serial, heap, snapshot, lock, or Arduino digitalRead'
$attach=[regex]::Match($source,'(?s)void r19_attach_aux_readiness_irq\(\).*?\n\}')
Check ($attach.Success-and$attach.Value.IndexOf('.edges.initialize(')-lt$attach.Value.IndexOf('gpio_install_isr_service')-and$attach.Value.IndexOf('gpio_install_isr_service')-lt$attach.Value.IndexOf('gpio_isr_handler_add')) 'ISR section initialized strictly before interrupt attachment'
Check (([regex]::Matches($source,'\.edges\.')).Count-eq2) 'edge section written only at pre-attach initialization and independent ISR'
$private=[regex]::Match($source,'(?s)bool r19_observe_usb_clock_reply_service\(\).*?\n\}')
Check ($private.Success-and$private.Value-match '(?s)const bool occupied = r19_service_usb_clock_reply\(\);.*?\.ready\.interval\(.*?R19UsbIntervalKind::PrivateReply.*?occupied\);.*?return occupied;') 'private-reply skip classification uses actual return result not unconditional scope'
Check ($private.Value-match '(?s)const bool private_boundary_held =.*?r19_usb_clock_reply_active \|\| r19_usb_clock_reply_fault.*?r19_usb_clock_reply_pending &&\s*r19_usb_private_reply_kind == R19UsbPrivateReplyKind::Ready.*?const bool occupied = r19_service_usb_clock_reply\(\);') 'active, failed, and start-blocked pending READY ownership sampled before service'
Check ($private.Value-match '(?s)\.ready\.interval\(.*?occupied\);.*?if \(occupied \|\| private_boundary_held\) \{.*?r19_observe_e220_aux\(monotonic_now_ms\(\)\);.*?return occupied;') 'service interval closes before one fresh observe-only AUX sample without changing return result'
Check (([regex]::Matches($private.Value,'r19_observe_e220_aux\(monotonic_now_ms\(\)\);')).Count-eq1) 'one bounded fresh-clock AUX observation in private ownership branch'
Check ($private.Value-match '(?s)r19_observe_e220_aux\(monotonic_now_ms\(\)\);\s*if \(e220_write_contract\.fail_closed\(\)\) \{\s*latch_runtime_fail_closed\(\);') 'unchanged AUX fail-closed result propagates into runtime safety latch'
Check (-not($private.Value-match 'normal_aux_observed\(')) 'auxiliary sample does not redefine ordinary-loop AUX bypass flag'
Check (-not($private.Value-match 'observe_radio_completion\(|take_write_completion\(|complete_standard_radio_writer_physical_tail\(|clear_standard_radio_writer_lease\(|complete_uart\(|observe_physical_tail\(')) 'private observer cannot consume completion or release UART/RF writer lease'
Check (-not($private.Value-match 'pump_ground_usb_egress\(|pump_local_egress\(|process_action\(|\.tick\(|radio_busy\s*=|pending_radio_action\s*=')) 'private observer cannot progress product egress, RF writes, TDD, or pending action'
Check (([regex]::Matches($source,'r19_observe_usb_clock_reply_service\(\)')).Count-eq3) 'both production call sites use observation wrapper'
$independent=[regex]::Match($source,'(?s)void r19_observe_ground_aux_without_completion\(\) noexcept \{.*?\n\}')
Check $independent.Success 'independent Ground AUX observer exists outside USB writer ownership'
Check ($independent.Value-match '(?s)r19_observe_e220_aux\(monotonic_now_ms\(\)\);\s*if \(e220_write_contract\.fail_closed\(\)\) \{\s*latch_runtime_fail_closed\(\);') 'independent observer samples fresh MCU clock and propagates permanent AUX fault'
Check (-not($independent.Value-match 'normal_aux_observed\(|observe_radio_completion\(|take_write_completion\(|complete_standard_radio_writer_physical_tail\(|clear_standard_radio_writer_lease\(|complete_uart\(|observe_physical_tail\(')) 'independent observer cannot redefine normal cadence or consume physical completion or lease'
Check (-not($independent.Value-match 'Serial\.|pump_ground_usb_egress\(|pump_local_egress\(|process_action\(|\.tick\(|radio_busy\s*=|pending_radio_action\s*=')) 'independent observer cannot progress USB/RF egress, TDD, or writer action'
$loop=[regex]::Match($source,'(?s)void loop_bridge\(\) noexcept \{.*')
Check ($loop.Success-and([regex]::Matches($loop.Value,'r19_observe_ground_aux_without_completion\(\);')).Count-eq3) 'diagnostic, ALIVE drain, and pre-normal stopped guards each sample once'
Check ($loop.Value-match '(?s)if \(r19_runtime_fail_diagnostic_staged \|\|.*?r19_runtime_diagnostic_committed_this_service\) \{\s*r19_observe_ground_aux_without_completion\(\);\s*return;') 'staged, flush-pending, failed and just-committed diagnostic exits retain observation'
Check ($loop.Value-match '(?s)if \(r19_ground_runtime_alive_reservation_pending\(\)\) \{\s*\{.*?R19AuxReadinessIntervalScope drain_interval\(R19UsbIntervalKind::AliveDrain\);.*?r19_drain_ground_runtime_alive_boundary\(monotonic_now_ms\(\)\);\s*\}\s*r19_observe_ground_aux_without_completion\(\);\s*return;') 'ALIVE drain interval closes before independent observation without changing ownership'
Check ($loop.Value-match '(?s)if \(!bridge_ready \|\| runtime_fail_closed\) \{\s*#if VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS && defined\(VC_LORA_PHASE6_GROUND\)\s*r19_observe_ground_aux_without_completion\(\);\s*#endif\s*return;') 'only diagnostic Ground pre-normal stopped guard adds read-only sampling'
Check ($source-match 'ClockFlushContext,\s*diagnostic_flush_budget_ms, r19_usb_clock_reply_epoch,\s*static_cast<std::uint32_t>\(diagnostic_deadline_us\),\s*static_cast<std::uint32_t>\(diagnostic_deadline_us >> 32U\)') 'flush budget and same-MCU absolute deadline recorded separately from 106ms product contract'
Check ($source.Contains('R19UsbIntervalKind::PrivateReply')-and$source.Contains('R19UsbIntervalKind::RuntimeDiagnostic')-and$source.Contains('R19UsbIntervalKind::AliveDrain')-and$source.Contains('R19UsbIntervalKind::Loop')) 'private reply, diagnostic, alive, loop intervals separated'
$outer=Get-Content -LiteralPath (Join-Path $RepoRoot 'tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1') -Raw
foreach($term in @('[switch]$AuxReadinessDiagnostics','Get-R19AuxReadinessCandidateContract','ConvertFrom-R19AuxReadinessRecord','aux_readiness_record')){
  Check ($outer.Contains($term)) "outer hook $term"
}
. (Join-Path $RepoRoot 'tools/r19_timed_path_outer.ps1')
$tools=@(Get-R19TimedPathOuterToolPaths -AuxReadinessDiagnostics $true)
Check ($tools.Count-eq18-and$tools[-1]-ceq'tools/read_r19_aux_readiness_record.ps1') 'opt-in decoder tool binding'
Check (@(Get-R19TimedPathOuterToolPaths).Count-eq17) 'old prepared tool count unchanged'
Write-Output "AUX_READINESS_BRIDGE PASS $script:n checks"
