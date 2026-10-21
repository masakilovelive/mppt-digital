# VC LoRa Phase 1～6 試験計画（履歴baseline＋現行追補）

履歴baseline実施日: 2026-08-24  
現行追補日: 2026-10-03  
対象: Vehicle / Ground XIAO ESP32S3、E220、Pixhawk、Mission Planner  
固定seed: `20260817`  
現行TDD制御プロトコル: `v2` explicit `UL_DONE`

Sections 1～9の件数、binary、HIL判定は2026-08-24時点の履歴である。現在の
受入状態と次の試験順序はSection 10を正とする。

## 1. 結論

- **Software / preflight: PASS**
  - 通常ホスト試験は161/161成功。論理結果は159 normal PASS、2 expected negative、0 unexpected FAIL。
  - production `E220WriteContract`を通す550 ms buffered transport、2-chunk continuation、
    started-transaction watchdogを検証済み。
  - Vehicle / Ground Arduino sketchは現行service-floor/watchdog変更を同期・clean compile・flash済み。
- **TDD diagnostic HIL: PASS**
  - Q起点の650 ms guard、遅延uplinkの64-byte atomic recovery、timeout後の遅延terminal回収が実機で成立。
  - 有効な`PARAM_REQUEST_READ` 1 frameはGround USBからVehicle D6 driver境界までexactに1回到達し、uplink timeoutとhalf-duplex overlapは0。
- **Deployment: NO-GO**
  - 現行v2 binaryを両roleへflashし、Heartbeat最大gap <= 2500 ms、
    parameter read/write、CRC/partial/control leakage 0を実機で再確認する。
  - 変更前v2の90秒HIL（Heartbeat最大gap 4098.309 ms）はfail-first比較証拠である。

## 2. 現行firmware契約

### 2.1 固定TDD値

| 項目 | 値 |
|---|---:|
| downlink send | 3000 ms |
| uplink guard | 650 ms |
| uplink admission window | 300 ms（whole-frame開始期限） |
| Vehicle receive timeout | 2000 ms |
| return guard | 650 ms |
| late terminal wait | 1300 ms |
| uplink application上限 | 64 byte |
| 1回のE220物理write上限 | 32 byte |
| E220 UART | 115200 bps |
| E220 air rate | 19200 bps |
| 同一nodeのminimum lower bound | 180 ms（production service floor 550 ms） |

`late_terminal_wait_ms=1300`はtimeout起点ReturnGuardの初期leaseの下限であり、hard上限ではない。遅延raw activityを時刻`t`で観測するたび、deadlineを`max(既存deadline, t + 650 ms)`へ延長する。有効terminalまたは明示discard後は通常のterminal時刻＋650 msへ切り替える。連続raw activityは安全側にguardを延長し続け得るため、noiseによるliveness低下は残余リスクとして扱う。

### 2.2 制御frame wire契約

- 制御プロトコルは`v2`のみを送受信対象とする。
- `UL_GRANT`、`UL_DONE`、`UL_IDLE`、`LINK_STATUS`はすべてexact32（32 byte固定）で、1 frameを1回のE220物理writeとして扱う。
- byte `0..19`は制御field、byte `20..29`は認証対象の予約領域で全byteを`0`に固定する。
- byte `30..31`はbyte `0..29`に対するCRC-16/CCITT-FALSEである。
- size、magic、payload length、予約領域、CRC、protocol、typeのいずれかが不正ならstate遷移させず、MAVLink endpointにも流さない。
- stream decoderとdemuxは旧形式候補が先行しても次の正しい32-byte frameへ再同期し、制御byteをapplication streamへ漏らさない。

### 2.3 Guard epoch

`G`をVehicle controllerが`UL_GRANT` writeをacceptした時刻、`Q`をその物理write完了、TX empty、AUX High安定を確認して`GrantDrain`を抜けた時刻とする。

- 650 msのuplink guardは`G`ではなく`Q`から開始する。
- Groundが受信したGRANTに対応して送信可能になる最早時刻まで、Vehicleは`UplinkReceive`を開かない。
- `Q`からfull 650 msの間もcurrent-cycle raw data/controlはtransaction quarantineへ受理できるが、
  terminal検証前にD6へcommitせず、Vehicle radio TXも開始しない。
- fixed scheduleの判定対象offset `Q+2624`、`Q+3176`、`Q+3282`、`Q+3832` msは100周期すべて期待stateで受理され、half-duplex overlapは0だった。

### 2.4 遅延uplinkのatomic recovery

- 同一session/cycleのuplink application dataを、`UplinkGuard`、`UplinkReceive`、timeout起点`ReturnGuard`をまたいで最大64 byteまでquarantineする。
- v2のdata cycleは1 GRANTにつき1 complete MAVLink frameとmatching `UL_DONE`を必要とし、
  両方を照合後にD6 driverへexactly onceでcommitする。
- 300 msはwhole-frame admission/start deadlineである。開始済みdescriptorは550 ms service-floor
  pacingで窓外まで有界継続し、64-wireは2 DATA＋DONEを2000 ms内に完了する。
  96-wire/oversizeはprefix 0のIDLEとする。
- 空cycleの`UL_IDLE`はversion、type、session、cycle、`actual_bytes=0`を厳密に照合する。
- CRC不正、identity不一致、terminal byte count不一致、overflow、別cycle混在は全体をdiscardする。閉windowではdemuxと部分parserをresetする。
- 部分dataはD6へ送信せず、quarantineを次cycleへ持ち越さない。link-data writeはraw `0x7E`でexact32へpaddingし、demuxでpaddingを破棄する。

### 2.5 MAVLink `PARAM_ERROR`

- `msg345 PARAM_ERROR`を定義し、CRC extra `209`、payload length `21`として検証する。
- parser allow-listとGround egressの両方で有効frameをexactに保持する。
- schedulerは`PARAM_ERROR`をurgent classとして扱い、通常telemetryより先に転送する。
- `UT-MAV-011`で定義、wire CRC、fixture round-trip、urgent分類、送出順序、Ground egressを検証する。

## 3. ホスト試験

### 3.1 実行方法

```powershell
tools\run_host_tests.ps1
```

個別再現例:

```powershell
.\build\host\tests\host\vc_lora_host_tests.exe `
  --test-case=UT-UPLINK-GUARD-EPOCH-001 `
  --seed=20260817 `
  --output-dir=runs\UT-UPLINK-GUARD-EPOCH-001 `
  --trace=runs\UT-UPLINK-GUARD-EPOCH-001\trace.csv
```

現行CTestでは`PHASE1-LEGACY-INVARIANT`と`IT-E220-BUFFERED-RF-HB-RED-001`を
`WILL_FAIL`として登録しているため、runner上は161/161成功、論理集計上は
159 normal PASS＋2 expected negativeとなる。

### 3.2 集計

| 集計 | 件数 | 結果 |
|---|---:|---|
| 全CTest | 161 | 161/161 success |
| 論理結果 | 161 | 159 normal PASS、2 expected negative、0 unexpected FAIL |

suiteにはlink escape/padding/accounting、MAVLink parser/scheduler、boundary、E2E、control protocol 2、
明示`UL_DONE`、guard epoch、遅延uplink recovery、buffered E220 service floor、started-transaction watchdog、
Ground USB heartbeat pacerを含む。

### 3.3 重点case

| ID / group | 主な検証 | 結果 |
|---|---|---|
| `UT-CONTROL-V2-WIRE-001` | exact32、予約領域zero、CRC位置とcoverage | PASS |
| `UT-CONTROL-V2-CORRUPTION-001` | padding/CRC corruptionのfail-close | PASS |
| `UT-CONTROL-V2-STREAM-001` | stream decodeと再同期 | PASS |
| `UT-CONTROL-V2-DEMUX-001` | control/application分離 | PASS |
| `UT-CONTROL-V2-MIXED-001` | 旧形式候補後の現行frame resync | PASS |
| `IT-CONTROL-SUBPACKET-TIMING-001` | 32-byte制御writeと送信間隔 | PASS |
| `IT-CONTROL-SUBPACKET-MSG20-001` | 制御trafficと32-byte `msg20`の共存 | PASS |
| `IT-CONTROL-SUBPACKET-HB-SLOT-001` | v2 explicit terminalとHeartbeat slot | PASS |
| `IT-E220-BUFFERED-UPLINK-001` | production write gate、exact32、Vehicle 45-byte/64-wire atomic commit、max buffer 64、remote gap 550/551 ms | PASS |
| `UT-GROUND-BOUNDED-CONTINUATION-001` | busy/zero-write/new sessionの2000 ms fail-closeと境界completion優先 | PASS |
| `UT-UPLINK-GRANT-DRAIN-001` | Q確定までguard epochを開始しない | PASS |
| `UT-UPLINK-GUARD-EPOCH-001` | Q起点full650と1300-ms timeout recovery | PASS |
| `UT-UPLINK-LATE-*` | 64-byte quarantine、identity、integrity、overflow、timing、terminal | 10/10 PASS |
| `IT-UPLINK-LATE-HIL-001` | 遅延HIL slot model | PASS |
| `IT-UPLINK-LATE-ESCAPE-001` | escape境界を含む遅延回収 | PASS |
| `UT-MAV-011` | `PARAM_ERROR` msg345 wire/priority/egress | PASS |
| `ST-001`～`ST-006` | 10000周期を含むstressと異常注入 | 6/6 PASS |
| `ST-MAV-001`, `ST-MAV-PHASE-001` | MAVLink長時間、Heartbeat phase sweep | 2/2 PASS |
| `FW-BUF/UART/SESSION/TIME/AUX/CONTRACT` | production adapter境界 | PASS |
| `FW-MAV-001/002`, `FW-SCHED-001` | allow-listとscheduler | PASS |
| `FW-CONTROL-WIRE-001` | production制御wire契約 | PASS |
| `FW-UPLINK-RESIDUAL-CONTRACT-001` | 閉window resetとegress保持 | PASS |
| `FW-USB-DISCONNECT-001` | USB切断・再接続のframe atomicity | PASS |

通常100周期の基準case `IT-TDD-001`はGRANT/DONE 100/100、uplink 100 transaction / 6400 byte、downlink 100 transaction / 3200 byteである。TX gate violation、Ground TX without grant、TX during RX、collision、control CRC error、uplink timeout、control leak、turnaround/half-duplex/UART dropはすべて0。

## 4. ASan / UBSan

現行550 ms service-floor / watchdog sourceでは、production write gateを通るbuffered transport、45-byte/64-wire Vehicle atomic commit、期限境界を通常host testで確認済みである。fresh full sanitizerも161/161成功し、ASan/UBSan/runtime-error markerは0である。正本は`runs/revalidation/host-sanitize-full-20260823T191756258Z/summary.json`とする。

以下はservice-floor変更前の履歴sanitizer結果であり、現行sourceの合格証拠には使用しない。

| 履歴Suite | 結果 | ASan | UBSan |
|---|---:|---:|---:|
| Phase 5 | 8/8 PASS | 0 | 0 |
| Phase 6 | 12/12 PASS | 0 | 0 |
| uplink/control重点 | 33/33 PASS | 0 | 0 |
| full CTest（履歴） | 134/134 success | 0 | 0 |

履歴v3 branchの全件ログは[`runs/diagnostics/tdd_v3_full_sanitizer_20260823/ctest_full.log`](runs/diagnostics/tdd_v3_full_sanitizer_20260823/ctest_full.log)にある。これは現行canonical v2ではない。

## 5. Arduino量産firmware build

### 5.1 再現方法

```powershell
tools\sync_arduino_sketch_core.ps1
tools\compile_arduino.ps1 -Fqbn esp32:esp32:XIAO_ESP32S3
```

環境はArduino CLI 1.3.1、ESP32 core 3.3.11、FQBN `esp32:esp32:XIAO_ESP32S3`。Vehicleを先、Groundを後にclean compileし、sketch-local core copyとcanonical sourceのcontractを検査する。3.3.11はHWCDC TXの欠落・永久停止を修正した3.3.9以降の実装を固定する。

### 5.2 現行成果物

| Sketch | Flash | Global RAM | `.bin` size | SHA-256 | 結果 |
|---|---:|---:|---:|---|---|
| Vehicle | 391803 byte (11%) | 97304 byte (29%) | 391952 byte | `4431DCB13DF662F91413700A8B2EFFE2F6A9E2A03473B6C3419C9C6C7CDBFC86` | PASS・flash済み |
| Ground | 364003 byte (10%) | 62848 byte (19%) | 364144 byte | `095C9BE529DFA24A544CAE544801B9E5D702CB181AFB87DBBD6DC62DAE334BCB` | PASS・flash済み |

- 対象source: 106 files
- source tree SHA-256: `B835173B1AA3837CEBDB94F1F0AEBFBC682EA0084E6A5E7D41F0C134DD2EE2D6`
- firmware manifest SHA-256: `BBE61DE437D8E624A8016A53AAFC72C43B5C12ED9038C54FFEE72B7393EB56E0`
- Ground production sourceのUSB debug text match: 0
- contract check: PASS

現行compile正本は[`runs/validation/final_production_compile_20260823T192757014Z/`](runs/validation/final_production_compile_20260823T192757014Z/)、upload正本は[`runs/hil/PROD-V2-PACING-HB-UPLOAD-001/20260823T194053048Z/`](runs/hil/PROD-V2-PACING-HB-UPLOAD-001/20260823T194053048Z/)とする。現行canonical v2のservice-floor/watchdog変更は両sketchへ同期・clean compile・flash済みである。

## 6. 実機flash

下表はservice-floor/watchdog変更前binaryの履歴であり、現行canonical v2の書込み証拠ではない。
現行書込みは上記upload正本でPASSしている。完全電源再投入とHILは未実施である。

| Role | Port | MAC | 書込byte | esptool hash | PNP再確認 | 結果 |
|---|---|---|---:|---|---|---|
| Vehicle | COM3 | `90:70:69:11:81:a4` | 322192 | verified | match | PASS |
| Ground | COM6 | `1c:db:d4:5a:83:80` | 350128 | verified | match | PASS |

旧flashのbinary SHA-256は当時のbuild表と一致する。証跡は[`runs/phase6_arduino_compile/flash_evidence.json`](runs/phase6_arduino_compile/flash_evidence.json)にあるが、現行canonical v2受入には使用しない。

## 7. Diagnostic TDD HIL

`late_terminal_wait_ms=1300`を含むdiagnostic firmwareをCOM3 / COM6へ書き込み、有効な32-byte `PARAM_REQUEST_READ(SERIAL1_BAUD)`をGround USBから1回送信した。

### 7.1 90秒測定の差分

| Counter | Vehicle差分 | Ground差分 |
|---|---:|---:|
| GRANT | +18 | +18 |
| DONE data terminal | +1 | TX +1 |
| IDLE terminal | +17 | TX +17 |
| uplink timeout | 0 | — |
| half-duplex drop | — | 0 |

Vehicleの対象transactionはradio ingress 32 byte / 1 frame / `msg20` 1、terminal `actual_bytes=32`、D6 driver commit 32 byte / 1 frame / `msg20` 1であった。CRC、invalid frame、outside-window data、overflow、duplicate/future/stale/expired、action retryは0。D7では4876有効MAVLink frame、CRC error 0を観測したが、`msg22`は0だった。

したがってTDD radio pathとlate terminal recoveryは**PASS**、D6 driverより先のPixhawk応答往復は未成立と判定する。主証跡:

- Vehicle before: [`response.txt`](runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204157304Z-vehicle-before/response.txt)
- Vehicle after: [`response.txt`](runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204417011Z-vehicle-after/response.txt)
- Ground before: [`response.txt`](runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204157304Z-ground-before/response.txt)
- Ground after: [`response.txt`](runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204417396Z-ground-after/response.txt)
- Ground 90秒capture: [`measurement.json`](runs/hil/E2E-MAV-LATE-TERMINAL-001/20260818T204238473Z-ground-com6/measurement.json)

## 8. 量産firmware HIL

### 8.1 条件

- Vehicle: COM3、Ground: COM6、Pixhawk direct control: COM26
- Ground USB: 57600 bps、8N1、DTR disabled
- request: 有効なMAVLink 2 `PARAM_REQUEST_READ`、parameter `SERIAL1_BAUD`、target `1/1`
- fixture: [`serial1_baud_request.bin`](runs/hil/E2E-MAV-PARAM-READ-VALID-001/serial1_baud_request.bin)
- fixture SHA-256: `821F1FE12A93B30FF42EEDB0CDA9CC7DE6A8D4D4E7347BDD2CB0B3A07572E2CC`
- capture時間: 90.013261秒

### 8.2 結果

| 判定項目 | 実測 | 合格条件 | 結果 |
|---|---:|---:|---|
| TX `msg20` | 1 valid frame / 32 byte | exact 1、CRC error 0 | PASS |
| RX MAVLink | 271 valid frame / 5390 byte | CRC/noise/partial 0 | PASS |
| TDD control leak | 0 | 0 | PASS |
| `msg22` after request | 0 | 1以上、`SERIAL1_BAUD`一致 | **FAIL** |
| `msg345` after valid request | 0 | 0 | PASS |
| Heartbeat | 115 frame | 継続受信 | PASS |
| Heartbeat最大gap | 4098.309 ms | 2500 ms以下 | **FAIL** |
| request後Heartbeat最大gap | 3548.751 ms | 2500 ms以下 | **FAIL** |

同一fixtureをCOM26へ直結したcontrol測定では`SERIAL1_BAUD`の`msg22`を1件、最初の応答を46.38 msで受信した。このためrequest内容とPixhawk parameter handlerは有効である。diagnostic HILでは同じrequestがD6 driverまでexactに1回到達している一方、D7 `msg22`は0である。

これは550 ms service-floor変更前のv2 fail-first HILである。判定は[`judgment.json`](runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/judgment.json)のとおり**FAIL**、capture正本は同directoryの[`measurement.json`](runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/measurement.json)、direct controlは[`measurement.json`](runs/hil/E2E-MAV-PARAM-VALID-DIRECT-POSTFIX-001/20260818T205427859Z-pixhawk-com26/measurement.json)である。

[`pixhawk_serial_parameters_readonly.json`](runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/pixhawk_serial_parameters_readonly.json)
はSERIAL1/2_PROTOCOL=2、BAUD=57、OPTIONS=0、MAV1/2_OPTIONS=0、BRD_SER1/2_RTSCTS=2 (Auto)を記録する。
要求値0と実機RTSCTS=2の不一致を次回切り分け対象とし、本計画更新でparameter mutationは行っていない。

## 9. 再試験前の必須確認

1. 現行canonical v2 Vehicle binaryをCOM3へ書き、再列挙・書込hashを保存する。
2. 同じsourceの現行canonical v2 Ground binaryをCOM6へ書き、再列挙・書込hashを保存する。片側だけ異なる版を混在させない。
3. Vehicle / Pixhawk / E220間の共通GND、3.3 V logic、TX/RX交差、選択connectorを確認する。
4. 同一fixtureでGround USB→radio→Vehicle D6→Pixhawk→Vehicle D7→radio→Ground USBの`msg20` / `msg22` exact round-tripを再測定する。
5. 90秒以上の再captureでMAVLink CRC/noise/partial/control leakが0、Heartbeat最大gapが2500 ms以下であることを確認する。
6. Mission Plannerのparameter readを確認した後に、影響が限定されたparameterでwrite/readbackを実施する。

上記6項目がすべてPASSになるまでDeployment判定はNO-GOを維持する。

## 10. R19 read-only CDC bootstrap追補（2026-10-03現行）

### 10.1 現在の判定

- accepted R18 productionはMission PlannerでPARAM_VALUE 932/932、strict index
  `0..931`、Heartbeat最大`2,206.203 ms`を同一区間で達成済みである。
- R19 diagnostic HILは2026-09-30に2回実施したが、両回Vehicle／Groundとも0 byteで
  `FAIL_NO_DIAGNOSTIC_BEACON`だった。各回の`finally` rollbackはaccepted R18への
  application-only write/readbackを完了した。
- 2回目capture正本は
  [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20260930T140653188Z/summary.json)、
  rollback正本は
  [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260930T140804219Z-f51cf7d1/flash_record.json)
  である。
- native HWCDC cached connectionとstrict read-only runnerの循環はofflineで成立する
  first-frame bootstrap bugだったが、唯一または十分な実機原因ではなかった。
- その旧修正を含むsealed diagnostic candidate `20261003T081053916Z-1a760fe3`は、
  2026-10-03にapplication-onlyで実機へ書込み済みである。40秒取得は3回目の
  `FAIL_NO_DIAGNOSTIC_BEACON`となり、Vehicle／Groundとも0 byte、R19A／R19F 0だった。
- 同run `20261003T083253345Z-5fc0094a`ではinstall readback、最大service gap
  Vehicle `66,228 us`／Ground `62,095 us`、serial write 0、parser clean、cleanup PASSを確認した。
  直後のaccepted R18 rollbackは両role初回成功であり、現在の両XIAOはaccepted R18である。
  正本はcapture
  [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T083253345Z-5fc0094a/summary.json)、
  install
  [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T083253345Z-5fc0094a-install/flash_record.json)、
  rollback
  [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T083253345Z-5fc0094a-rollback/flash_record.json)
  である。
- 追加の診断macro限定修正は、SOF由来`isPlugged()`をbootstrap hard gateにせず、ISR-latched
  host pickupをreset／quarantine検査後のwitnessとし、publication fence解除後にexplicit
  empty-FIFO/ZLP kickを発行する。normal 301/301、fresh ASan＋UBSan 301/301、HWCDC semantic
  33/33、installer `-CheckOnly`、両role compile、独立candidate verifierはPASSした。
- 旧candidateを再利用せず、fresh diagnostic candidate `20261003T091702033Z-e3aa5200`を
  offlineで生成・封印した。candidate manifestの`hardware_interaction=false`、opened COM 0、flash falseは
  package生成時の事実であり、このpackageは後続の別HIL証跡で一回だけ実機へ書込み済みである。
- `acceptance_eligible=false`、`acceptance_authorized=false`、`deployment_authorized=false`は継続する。
- R19 932件30秒とHeartbeat最大2,500 msの実機同時達成は未証明であり、NO-GOを維持する。

### 10.2 false-SOF／ZLP candidate実機結果

一回限定許可でartifact `20261003T091702033Z-e3aa5200`をVehicle→Groundへapplication-onlyで書込み、
COM3 `115200 bps`／COM6 `57600 bps`を40秒read-only取得した。run IDは
`20261003T094504443Z-32368ca4`である。

| 工程 | 判定 | 正本 |
|---|---|---|
| install | `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY` | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-install/flash_record.json) |
| 40秒capture | **`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`** | [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T094504443Z-32368ca4/summary.json) |
| accepted R18 rollback | `PASS_R18_ROLLBACK_COMPLETE` | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-rollback/flash_record.json) |

Vehicleは0 byte／0 frame／R19A・R19F 0、最大service gap `98,532 us`、Groundも0 byte／0 frame／
R19A・R19F 0、最大service gap `50,185 us`だった。serial write 0、cleanup PASSであり、false-SOF／ZLP修正も
物理0 byteを解消しなかった。入力がないためparser cleanはparser動作の物理証明ではなく、RF／TDDも未評価である。
両roleはaccepted R18へ初回で復旧済みで、この一回限定許可は消費済みである。

diagnostic PASSはCDC bootstrapとfailure observabilityの物理証明であり、30秒製品受入ではない。

### 10.3 次回diagnostic分離試験

同じartifactを再使用しない。次は共通early-boot、diagnostic publisher、HWCDC ring／FIFO、USB INの境界を
CDC自己報告に依存しないstage evidenceまたは最小CDC canaryでtest-first分離する。offline suite、sanitizer、
HWCDC semantic、両role compile、封印・独立検証まで完了した新artifactだけを、別の一回限定許可後にHILへ使用する。
有効なrole別R19A／R19Fを取得するまで製品受入へ進まない。

### 10.4 次回product受入

diagnostic HIL成立後に、別許可・別artifact・別証拠区間でMission Planner＋Pixhawk＋E220の
製品試験を行う。同一区間で次をすべて満たした場合だけR19 30秒受入をPASSとする。

- PARAM_VALUE exact 932件、strict index `0..931`
- missing、duplicate、out-of-order、out-of-range、count mismatchがすべて0
- `t1 - t0 <= 30,000,000 us`
- primary Heartbeat first／max／post gapがすべて`<=2,500,000 us`
- CRC、partial、noise、control leakage、parser、retry identity、tail、VCRC errorがすべて0

一項目でも不合格または証拠不足ならaccepted R18を維持し、受入基準を緩和しない。
