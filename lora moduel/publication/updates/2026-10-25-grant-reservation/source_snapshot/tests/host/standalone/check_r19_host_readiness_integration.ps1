param(
  [string]$RepoRoot=(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
  [string]$OutputRoot=''
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body) {
  try { & $Body; $checks.Add([ordered]@{name=$Name;passed=$true}) }
  catch { $checks.Add([ordered]@{name=$Name;passed=$false;error=$_.Exception.Message}) }
}
function Require([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Get-Body([string]$Source,[string]$Marker) {
  $start=-1;$open=-1
  do {
    $start=$Source.IndexOf($Marker,$start+1,[StringComparison]::Ordinal)
    if($start-lt0){throw "Missing function definition $Marker"}
    $open=$Source.IndexOf('{',$start)
    $semi=$Source.IndexOf(';',$start)
  } while($semi-ge0-and$semi-lt$open)
  $depth=0
  for($i=$open;$i-lt$Source.Length;++$i){
    if($Source[$i]-eq'{'){++$depth}
    elseif($Source[$i]-eq'}'){--$depth;if($depth-eq0){return $Source.Substring($open,$i-$open+1)}}
  }
  throw "Unclosed function $Marker"
}
$bridge=Get-Content -LiteralPath (Join-Path $repo 'firmware/phase6/vc_lora_phase6_bridge.hpp') -Raw
Check 'readiness-default-off-and-diagnostic-only' {
  Require ($bridge-match'#define\s+VC_LORA_R19_USB_READINESS_MODE\s+0') 'Readiness must default off'
  Require ($bridge.Contains('#error "R19 USB readiness modes require runtime diagnostics"')) 'Readiness must reject product/non-diagnostic builds'
  Require ($bridge.Contains('VC_LORA_R19_USB_READINESS_MODE > 2')) 'Unknown readiness mode must be rejected'
}
Check 'original-product-deadline-unchanged' {
  Require ($bridge-match'kGroundUsbHeartbeatCommitDeadlineMs\s*=\s*106U') '106 ms product contract changed'
  $body=Get-Body $bridge 'void observe_ground_paced_heartbeat_commit('
  Require ($body.Contains('const TxResult result = publication_succeeded ? TxResult::Accepted')-and
    $body.Contains('latch_runtime_fail_closed();')) 'Product publication failure no longer fails closed'
  Require (-not $body.Contains('admit_validated_frame')) 'A fully accepted failed heartbeat may not be replayed'
}
foreach($case in @(
  @('heartbeat','bool admit_ground_paced_heartbeat(','radio_application_endpoint.admit_validated_frame'),
  @('ordered-backlog','bool replay_ground_usb_ordered_backlog(','radio_application_endpoint.admit_validated_frame'),
  @('normal-rf','void handle_ground_validated_frame(','radio_application_endpoint.admit_validated_frame'),
  @('r19-bulk','bool r19_route_ground_usb_output(','radio_application_endpoint.admit_validated_frame')
)) {
  $name=$case[0];$marker=$case[1];$admit=$case[2]
  Check "gate-before-irreversible-$name-admission" {
    $body=Get-Body $bridge $marker
    Require ($body.IndexOf('r19_product_usb_publication_allowed()')-ge0-and
      $body.IndexOf('r19_product_usb_publication_allowed()')-lt$body.IndexOf($admit)) 'Product USB admission bypasses HostArm gate'
  }
}
Check 'defensive-physical-pump-gate' {
  $body=Get-Body $bridge 'void pump_ground_usb_egress('
  Require ($body.IndexOf('r19_product_usb_publication_allowed()')-ge0-and
    $body.IndexOf('r19_product_usb_publication_allowed()')-lt$body.IndexOf('pump_local_egress_if_connected')) 'Physical product pump bypasses gate'
}
Check 'waiting-gate-does-not-pause-heartbeat-expiry' {
  $body=Get-Body $bridge 'void service_ground_usb_heartbeat_pacer('
  Require ($body.Contains('r19_expire_waiting_host_heartbeats(observed_ms)')) 'Held heartbeats do not expire while arm pending'
  $expire=Get-Body $bridge 'void r19_expire_waiting_host_heartbeats('
  Require ($expire.Contains('ground_usb_heartbeat_pacer.expire(now_ms)')-and
    $expire.Contains('recover_ground_stale_pacer_pair(now_ms)')) 'Expired pacer/backlog pairing can remain stale'
}
Check 'header-dependency-closure' {
  $sync=Get-Content -LiteralPath (Join-Path $repo 'tools/sync_arduino_sketch_core.ps1') -Raw
  $common=Get-Content -LiteralPath (Join-Path $repo 'tools/r19_candidate_artifact_common.ps1') -Raw
  Require ($sync.Contains('IncludeR19UsbReadinessDiagnostics')-and
    $sync.Contains('firmware\diagnostics\r19_host_readiness.hpp')) 'Readiness dependency requires a separate explicit opt-in'
  Require (-not $common.Contains("'r19_host_readiness.hpp'")) 'Unsealed A/B dependency polluted frozen candidate header allowlist'
  Require ($bridge.Contains('#include "diagnostics/r19_host_readiness.hpp"')-and
    (Test-Path -LiteralPath (Join-Path $repo 'firmware/diagnostics/r19_host_readiness.hpp'))-and
    -not (Test-Path -LiteralPath (Join-Path $repo 'firmware/high_speed/r19_host_readiness.hpp'))) 'Readiness header is not isolated outside the frozen package'
}
Check 'arm-namespace-is-local-and-after-ready-publication' {
  $body=Get-Body $bridge 'bool r19_intercept_usb_clock_request('
  Require ($body.Contains('r19_is_host_readiness_namespace(frame)')-and
    $body.Contains('r19_usb_ready_publication_complete')-and
    $body.Contains('r19_host_readiness_gate.accept_arm')) 'ARM is not locally consumed and bound to completed READY'
}
Check 'clock-completion-stages-ready-with-same-writer' {
  $body=Get-Body $bridge 'bool r19_service_usb_clock_reply()'
  Require ($body.Contains('r19_host_readiness_gate.record_clock_reply')-and
    $body.Contains('r19_encode_host_readiness_frame')-and
    $body.Contains('r19_usb_clock_reply_offset += accepted')) 'READY does not reuse exact-once diagnostic writer'
}
Check 'initialization-precedes-product-setup-and-preserves-default' {
  $body=Get-Body $bridge 'void setup_bridge()'
  Require ($body.Contains('r19_begin_usb_readiness_diagnostic()')-and
    $body.IndexOf('r19_begin_usb_readiness_diagnostic()')-lt$body.IndexOf('provision_boot_identity')) 'Gate initialized too late'
  $gate=Get-Body $bridge 'bool r19_product_usb_publication_allowed()'
  Require ($gate.Contains('#if VC_LORA_R19_USB_READINESS_MODE == 2')-and
    $gate.Contains('return true;')) 'Default and SyncOnly must not gate product'
}
Check 'no-arm-acquisition-is-bounded-before-first-nonce' {
  $setup=Get-Body $bridge 'void r19_begin_usb_readiness_diagnostic()'
  $gate=Get-Body $bridge 'bool r19_product_usb_publication_allowed()'
  Require ($setup.Contains('r19_usb_readiness_acquisition_deadline_us')-and
    $gate.Contains('r19_usb_readiness_acquisition_deadline_us')-and
    $gate.Contains('latch_runtime_fail_closed();')) 'No-nonce waiting is unbounded'
}
Check 'clock-header-is-owned-by-one-include-route-per-mode' {
  # Xtensa GCC on Windows can treat slash/backslash aliases as distinct
  # pragma-once files. The readiness header already owns its clock dependency.
  Require ($bridge-match'(?s)#if VC_LORA_R19_USB_READINESS_MODE != 0\s+#include "diagnostics/r19_host_readiness.hpp"\s+#else\s+#include "high_speed/r19_usb_clock_sync.hpp"\s+#endif') 'Diagnostic and legacy routes include the same clock definitions twice'
}
$result=[ordered]@{schema='vc-lora-r19-host-readiness-integration-offline-v1';result=$(if(@($checks|Where-Object {-not $_.passed}).Count-eq0){'PASS'}else{'FAIL'});hardware_interaction=$false;product_deadline_ms=106;checks=@($checks);check_count=$checks.Count;failed_count=@($checks|Where-Object {-not $_.passed}).Count}
if($OutputRoot){
  New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'summary.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
$result|ConvertTo-Json -Depth 8
if($result.failed_count-ne0){exit 1}
