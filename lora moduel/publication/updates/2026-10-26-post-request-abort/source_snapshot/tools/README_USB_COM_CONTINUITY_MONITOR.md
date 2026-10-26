# USB/COM continuity monitor

`monitor_usb_com_continuity.ps1`は、次回HIL中のXIAO USB CDC列挙を
通信データ面とは独立に記録する読取り専用モニタです。COMポートを生成・
openせず、次の値を250 msごとに確認します。

- Vehicle: `COM3` / `USB\VID_303A&PID_1001&MI_00\7&7131F6A&0&0000`
- Ground: `COM6` / `USB\VID_303A&PID_1001&MI_00\7&2159A644&0&0000`
- ConfigMgr上のpresent、started、problem code、`LastArrivalDate`
- 各device instanceの読取り専用`PortName`と、現在のSerialComm map件数

起動時に限り`powercfg.exe /GETACTIVESCHEME`と`/QH`を実行し、active
scheme、USB selective suspend、USB 3 Link Power ManagementのAC/DC値を
`startup_metadata.json`へ固定します。power settingの変更コマンドはありません。

## HILとの並走

初回の型コンパイル、`powercfg`、ConfigMgrウォームアップをHILのfairness
区間から外すため、必ず`monitor_ready.json`を待ってからHIL runnerを開始します。

```powershell
$repo = 'E:\VESC\TRIAL_LOG\Loreley3_System\06_vc_lora_bridge'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$monitorOut = Join-Path $repo "runs\hil\USB-COM-CONTINUITY-001\$stamp"
$stopMarker = Join-Path $monitorOut 'stop.request'
$monitorScript = Join-Path $repo 'tools\monitor_usb_com_continuity.ps1'

$monitor = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru `
    -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
      '-File',$monitorScript,'-OutputDirectory',$monitorOut,
      '-StopSignalPath',$stopMarker,'-DurationSeconds','7200')

while (-not (Test-Path -LiteralPath (Join-Path $monitorOut `
    'monitor_ready.json'))) {
  Start-Sleep -Milliseconds 100
}

# ここでHIL runnerを開始する。

[IO.File]::WriteAllText($stopMarker, 'stop',
    (New-Object Text.UTF8Encoding($false)))
Wait-Process -Id $monitor.Id
```

HILを先に別processとして起動する場合は、`-WatchProcessId <HIL PID>`でも
そのprocess終了時にmonitorを正常終了できます。強制killではJSONLの既書込み行は
残りますが`summary.json`は作られないため、stop markerまたはprocess監視を使います。

## 証跡

- `startup_metadata.json`: 起動時の不変メタデータ。ローカライズされた
  `powercfg`出力はJSON破損を避けるためUTF-8 Base64で保持します。
- `events.jsonl`: 最初のsnapshot、状態変化、10秒checkpoint、停止を
  WriteThrough + `Flush(true)`で追記します。全250 ms pollは書き込みません。
- `monitor_ready.json`: HIL開始可能を示すdurable markerです。
- `summary.json`: LastArrival変化、present/absent遷移、COM map異常、query時間、
  COM open数（常に0であること）の集計です。
- `artifact_hashes.json`: 上記4証跡のSHA-256です。

予定されたHIL開始時の電源OFF/ONも状態変化として記録されるため、全期間の
`continuity_preserved`はfalseになります。異常判定時は`events.jsonl`のUTCを
runnerの`ports_opened`または`request_sent`以降に合わせて評価してください。
250 msより短く、PnPの再到着にもならない瞬断は捕捉できない可能性があります。

## Disk-only selftest

```powershell
& "$repo\tools\monitor_usb_com_continuity.ps1" -SelfTest `
    -SelfTestEvidenceDirectory "$repo\runs\validation\USB-COM-MONITOR-SELFTEST"
& "$repo\tests\hil\check_usb_com_continuity_monitor_contract.ps1"
```

selftestは固定snapshotだけを使い、hardware query、`powercfg` process、COM openを
いずれも0件のまま、切断、再到着、LastArrival更新、COM6重複、復旧を検証します。
