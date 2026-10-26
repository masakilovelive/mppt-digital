# Definitions only. No device, port, process, clock, or network operation.
# File fingerprints are sampled only by the explicit source-contract constructor.
function Assert-R19UsbRoleCapabilityShape {
  param([object]$Contract)
  if($null-eq$Contract-or$Contract.schema-cne'vc-lora-r19-usb-role-capabilities-v1'-or
     $Contract.mode-cne'ExplicitHostArm'-or$Contract.implementation_bound-isnot[bool]-or-not$Contract.implementation_bound){throw 'Missing or unsupported versioned USB role capabilities'}
  $expectedSources=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1')
  $sources=@($Contract.canonical_sources)
  if($sources.Count-ne$expectedSources.Count){throw 'USB role capability source inventory is incomplete'}
  foreach($path in $expectedSources){
    $rows=@($sources|Where-Object{$_.path-ceq$path})
    if($rows.Count-ne1-or$rows[0].sha256-isnot[string]-or$rows[0].sha256-cnotmatch'^[0-9A-F]{64}$'){throw 'USB role capability source fingerprint is absent or malformed'}
  }
  $roles=@($Contract.roles)
  if($roles.Count-ne2){throw 'USB role capability inventory must contain exactly two roles'}
  foreach($expected in @(@('vehicle','SyncOnly',$false,$false),@('ground','ExplicitHostArm',$true,$true))){
    $rows=@($roles|Where-Object{$_.role-ceq$expected[0]})
    if($rows.Count-ne1){throw 'USB role capability role is missing or duplicated'}
    $r=$rows[0]
    foreach($flag in @('clock_request_reply','ready','arm')){if($r.$flag-isnot[bool]){throw 'USB role capability flag must be boolean'}}
    if(-not$r.clock_request_reply-or$r.effective_mode-cne$expected[1]-or$r.ready-ne$expected[2]-or$r.arm-ne$expected[3]){throw 'USB role capability is unsupported or escalates Vehicle admission'}
  }
}

function Get-R19UsbRoleCapabilities {
  param([string]$RepoRoot,[string]$Mode='ExplicitHostArm',[bool]$Enabled=$false)
  if(-not$Enabled){return $null}
  if($Mode-cne'ExplicitHostArm'){throw 'Bound USB role capabilities require ExplicitHostArm diagnostic mode'}
  $relative=@('firmware/phase6/vc_lora_phase6_bridge.hpp','firmware/high_speed/r19_diagnostic_usb_failure_record.hpp','tools/r19_usb_role_contract.ps1')
  $bridgePath=Join-Path $RepoRoot $relative[0]
  $bridge=Get-Content -LiteralPath $bridgePath -Raw -ErrorAction Stop
  foreach($symbol in @('r19_collect_vehicle_usb_clock_requests','r19_service_vehicle_usb_clock_reply','r19_intercept_usb_clock_request','vc_lora_r19_diagnostic_usb_failure_record')){
    if($bridge-notmatch('\b'+[regex]::Escape($symbol)+'\b')){throw ('USB role declaration is not implemented in canonical bridge: '+$symbol)}
  }
  $sources=@(foreach($path in $relative){[pscustomobject][ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $path) -Algorithm SHA256 -ErrorAction Stop).Hash}})
  [pscustomobject][ordered]@{
    schema='vc-lora-r19-usb-role-capabilities-v1';mode=$Mode;implementation_bound=$true
    canonical_sources=$sources
    roles=@(
      [pscustomobject][ordered]@{role='vehicle';clock_request_reply=$true;effective_mode='SyncOnly';ready=$false;arm=$false},
      [pscustomobject][ordered]@{role='ground';clock_request_reply=$true;effective_mode='ExplicitHostArm';ready=$true;arm=$true})
  }
}

function Assert-R19UsbRoleCapabilities {
  param([object]$Contract,[string]$RepoRoot,[string]$Mode='ExplicitHostArm')
  Assert-R19UsbRoleCapabilityShape $Contract
  $expected=Get-R19UsbRoleCapabilities -RepoRoot $RepoRoot -Mode $Mode -Enabled $true
  if(($Contract|ConvertTo-Json -Depth 15 -Compress)-cne($expected|ConvertTo-Json -Depth 15 -Compress)){throw 'USB role capabilities differ from exact canonical implementation fingerprints'}
}

function Get-R19UsbRoleEffectiveMode {
  param([object]$Contract,[ValidateSet('vehicle','ground')][string]$Role,
    [ValidateSet('SyncOnly','ExplicitHostArm')][string]$RequestedMode,[switch]$AllowLegacyV0)
  if($null-eq$Contract-and$AllowLegacyV0){
    # Explicit compatibility with historical role-name-derived workflow v0.
    # This preserves its behavior; it does NOT declare Vehicle support.
    if($Role-ceq'vehicle'){return 'SyncOnly'}
    return $RequestedMode
  }
  Assert-R19UsbRoleCapabilityShape $Contract
  if($RequestedMode-cne$Contract.mode){throw 'Requested mode is not bound to the role capability contract'}
  return @($Contract.roles|Where-Object{$_.role-ceq$Role})[0].effective_mode
}

function Assert-R19UsbRolePrivateWrite {
  param([object]$Contract,[ValidateSet('vehicle','ground')][string]$Role,
    [ValidateSet('ClockRequest','Arm')][string]$Kind)
  Assert-R19UsbRoleCapabilityShape $Contract
  $cap=@($Contract.roles|Where-Object{$_.role-ceq$Role})[0]
  if(($Kind-ceq'ClockRequest'-and-not$cap.clock_request_reply)-or($Kind-ceq'Arm'-and-not$cap.arm)){throw 'Private USB write is not supported by the exact role contract'}
}
