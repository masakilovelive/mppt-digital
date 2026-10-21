# VC LoRa Phase 6 HIL試験計画

## 1. 現在の位置付け

本書はPhase 6 production firmwareを実機へ書き込む前の試験計画である。
現時点では書込みを許可しない。productionの固定配線、UART、E220プロファイル、
TDD値は変更しない。

HIL結果はhostと同じテストIDで`runs/hil/<TEST-ID>/`へ保存する。ただし、PCで取得した
1本のcaptureだけではPASSにしない。必要な全endpoint、ロジックアナライザ波形、firmware
hash、operator checklistが揃った時だけ、個別IDをPASSと判定する。

## 2. 診断経路とMAVLink純度

### 2.1 productionで許可する経路

- Ground native USB CDCはMission Planner向けMAVLink byte stream専用とする。
- Ground USBへ`print`、`printf`、JSON、CSV、状態文字列、独自binary recordを出さない。
- VehicleのPixhawk UART D6/D7にも診断byteを出さない。
- E220 transparent streamへ診断を混入させない。
- production firmwareではVehicle USB CDC、LED、BLEを合否判定の必須経路にしない。

Ground USBを診断とMAVLinkで多重化した場合、文字列だけでなく独自binaryもMAVLink parserを
破壊するため禁止する。

### 2.2 非侵襲な観測方法

次の3経路を使い分ける。

1. **Ground USB raw capture**
   Mission Plannerを完全終了してから`tools/hil_capture_serial.ps1`がCOMを専有する。
   RX/TXをbinaryのまま保存し、文字コード変換しない。
2. **Mission Planner `.tlog`**
   実Pixhawk接続試験ではMission PlannerがGround COMを直接専有する。同時にraw captureを
   起動しない。接続画面、Messages、`.tlog`を証拠として保存する。
3. **外部ロジックアナライザ**
   XIAOとE220のUART/AUX、および必要時のみPixhawk UARTを高インピーダンスで観測する。
   firmwareへ診断byteを追加せず、session、control frame、write長、間隔、AUX波形を測る。

将来、内部counterがどうしても必要な場合は、productionとは別hash・別名称のHIL専用buildで
Vehicle native USBだけへ出力する。Ground USBへはHIL buildでも診断を出さない。HIL専用buildの
結果はproduction実測の代用にせず、fault injectionの補助証拠として区別する。

## 3. 安全なベンチ構成

### 3.1 自動fixture構成

- Pixhawkの代わりに3.3 V TTL USB-UARTをVehicle D6/D7へ接続する。
  - fixture TX → Vehicle D7（XIAO RX）
  - fixture RX ← Vehicle D6（XIAO TX）
  - GND共通
- USB-UARTの5 V端子は接続しない。
- Groundはnative USB CDCでPCへ接続する。
- E220 2台には920 MHz帯対応アンテナを先に接続し、約1 m離す。
- E220電源、XIAO電源、GND、M0/M1を電源OFF状態で結線確認する。

この構成で固定fixture、burst、Heartbeat停止を再現する。実flight controllerのparameterや
actuatorへ影響しないため、`E2E-MAV-002`、`006`～`010`を先に行う。

### 3.2 実Pixhawk/Mission Planner構成

- propeller、motor出力、actuator電源を外し、PixhawkをDISARMEDで使用する。
- Pixhawk parameterを全保存し、試験後に差分を確認する。
- Ground COMは57600 bpsでMission Plannerだけが開く。
- `PARAM_SET`を行う場合は、事前承認された非作動系parameter 1個だけをallow-listへ記録し、
  元値を保存して試験直後に復元する。allow-listがない場合`E2E-MAV-004`は実Pixhawkで実施しない。
- `COMMAND_LONG`は非作動の`MAV_CMD_REQUEST_MESSAGE`だけを使用する。ARM、mode変更、reboot、
  calibration、mission実行コマンドは禁止する。

### 3.3 ロジックアナライザ接続点

各信号は3.3 V logic、GND共通、高インピーダンス入力で観測する。

| Node | 信号 | XIAO header | 用途 |
|---|---|---|---|
| Vehicle | XIAO→E220 | D2 | downlink data、`UL_GRANT`、write burst |
| Vehicle | E220→XIAO | D3 | uplink data、`UL_DONE/IDLE` |
| Vehicle | E220 AUX | D8 | 連続HIGH dwell、任意LOW→HIGH、High安定時間 |
| Vehicle | XIAO→Pixhawk | D6 | Groundから戻るGCS frame |
| Vehicle | Pixhawk→XIAO | D7 | Pixhawk MAVLink入力 |
| Ground | XIAO→E220 | D2 | uplink data、`UL_DONE/IDLE` |
| Ground | E220→XIAO | D3 | downlink data、`UL_GRANT` |
| Ground | E220 AUX | D8 | 連続HIGH dwell、任意LOW→HIGH、High安定時間 |

両nodeを同時測定するためPC接地で離れたGNDを強制接続しない。必要なら絶縁された2台の
analyzerを使う。1台だけの場合は試験をVehicle側とGround側に分ける。

UART decoderはE220側115200 8N1、Pixhawk側57600 8N1、LSB first、non-invertedとする。

## 4. 証拠形式

各試験IDで次を保存する。

```text
runs/hil/<TEST-ID>/<UTC>-<endpoint>/
  capture.jsonl
  capture_metadata.json
  rx.bin
  tx.bin
  measurement.json
  logic.csv または logic.sal
  wiring.jpg
  operator_checklist.json
```

`capture.jsonl`は時刻付きBase64 byte chunkであり、`rx.bin`/`tx.bin`が原byteである。
`measurement.json`は`hil_analyze_capture.py`が作る測定値で、statusは必ず
`ANALYZED_NOT_YET_JUDGED`となる。単独captureを自動でPASSにしないためである。

directionはPCから見た向きである。`ground_usb`のRXはGround→PC、TXはPC→Ground、
`pixhawk_fixture`のRXはVehicle D6→fixture、TXはfixture→Vehicle D7となる。

最終`operator_checklist.json`には最低限、次を残す。

- `test_id`
- `result`: `PASS`、`FAIL`、`BLOCKED`
- Vehicle/Ground firmware SHA-256
- board FQBNとArduino core version
- E220両側8-byte readback
- antenna、距離、電源電圧
- capture/logic/tlogのSHA-256
- operator、開始/終了UTC
- 実測値とhost基準値
- 最初の不一致、再現手順

## 5. captureツール

### 5.1 Ground USBのbinary capture

Mission PlannerとArduino Serial Monitorを閉じてから実行する。

```powershell
.\tools\hil_capture_serial.ps1 `
  -Port COM6 `
  -TestId E2E-MAV-001 `
  -Endpoint ground_usb `
  -DurationSeconds 65 `
  -Baud 57600
```

既存証拠は上書きしない。`-DtrEnable`は明示時だけ有効になり、COM openによる意図しない
resetを避ける。fixtureをGroundへ一度だけ送る場合は`-TransmitFile`と
`-TransmitDelayMs`を指定する。

### 5.2 MAVLink/control測定

このPCでは通常の`python`がPATHにない場合がある。既存のPython 3.12 fallbackを例にする。

```powershell
$pythonExe = Join-Path $env:LOCALAPPDATA `
  'Programs\Python\Python312-32\python.exe'
& $pythonExe .\tools\hil_analyze_capture.py `
  --input  .\runs\hil\E2E-MAV-001\<capture>\capture.jsonl `
  --output .\runs\hil\E2E-MAV-001\<capture>\measurement.json `
  --test-id E2E-MAV-001
```

解析器はproduction coreと同じ`mavlink_frame.cpp`定義を読み、定義sourceのSHA-256も結果へ
記録する。MAVLink v1/v2 CRC、msgid/source別frame数、raw/valid hash、Heartbeat最大gap、
raw `VCTD` controlのCRC/session/cycle/guard/windowを測る。

radio UART captureはapplication dataがescapeされ、controlと混在する。radio UART上のMAVLink
集計は合否に使わず、`tdd_control`集計とraw waveformだけを使う。MAVLink exactnessはGround
USBまたはPixhawk fixture endpointで判定する。

すべてのlocal endpoint captureで、次を共通不変条件とする。

- `tdd_control.valid == 0`（GRANT/DONE/IDLEがPixhawkまたはMission Plannerへ漏れない）
- 対象となるMAVLink frameの`bad_crc == 0`
- 送信fixtureと受信frameのbyte数、順序、SHA-256が一致する
- partial MAVLink frameを成功として数えない

### 5.3 Ground USB切断・再接続

`FW-USB-DISCONNECT-001`は、Mission Planner/COM6を開かない状態でも無線TDDが停止しないことを
確認する。両側を新firmwareで再起動後、COM6を最低180秒閉じたままにする。その後COM6を
30秒captureし、いったん閉じて再度180秒待ち、同じ30秒captureをもう一度行う。

各captureは開始直後のUSB/OS backlogだけで合格にしない。少なくともcapture終了前5秒以内に
CRC-valid Heartbeatがあり、`bad_crc == 0`、`tdd_control.valid == 0`、完全frame以外を成功数へ
含めないことを必須とする。先頭にポートopen以前のframe断片があってもnoiseとして分離し、
以後の完全frame CRCとHeartbeat継続性で判定する。2回とも再起動なしで合格後、Mission Plannerを
COM6/57600で接続し、parameter取得が進むことを確認する。

## 6. host IDとHIL判定の対応

### 6.1 runtime契約

| Test ID | 実機操作 | 必須証拠 | HIL合格条件 |
|---|---|---|---|
| `FW-SESSION-001` | Vehicleを完全電源断して3回boot。各回2周期以上capture | Vehicle D2/D3 UART control、boot時刻 | sessionが全て非0、bootごとにmodulo順で新しく、Groundが2周期以内に新sessionへ復帰。旧session送信0 |
| `FW-TIME-001` | 10分連続運転後に双方を個別reset | Heartbeat/control時刻、deadlock有無 | 観測時刻後退0、timeout暴走0、reset後2周期以内復帰 |
| `FW-AUX-001` | 32 byte以下/超frame、AUX busy faultを各1回 | D2 UART burstとD8波形 | 物理write各≤32 byte。Accepted後はAUXが連続HIGHでもLOW→HIGHでもfull受付から550 ms未満に完了/次writeせず、550 ms経過かつHIGH連続≥15 msでone-shot完了。LOWからHIGH復帰しない状態が2 s続けば通常TX停止 |
| `FW-USB-DISCONNECT-001` | Ground COMを180秒以上閉じ、30秒captureする操作を再起動なしで2回 | 各capture、Heartbeat時刻、CRC/noise/control集計 | 容量超過時もTDD継続。新着完全frameだけをdrop-newestし、既存FIFO/送信中suffixを変更しない。各capture終端5秒以内に有効Heartbeat、CRC error/control漏れ0。再接続後にparameter取得可能 |
| `FW-CONTRACT-001` | 正常profile readback後boot。別runでE220 TXD→XIAO RX（D3）を電源OFF中に外してread failure | profile 8 byte、pin写真、UART decode、fail-close波形 | 正常値完全一致。read失敗runは設定read要求後にnormal mode radio data/GRANTを送らない。再接続は必ず電源OFFで行う |

`FW-SESSION-001`の`0xFFFF→1` wrapと`FW-TIME-001`の32-bit clock wrapは短時間production
HILでは到達できない。これらはhostの同一IDを必須証拠とし、実機完全判定には次のどちらかを
追加する。

- production binaryを変更しない49.8日以上のsoak capture
- productionと別hashのVehicle USB専用HIL buildによるinitial state injection

どちらも未実施なら、該当IDの実機coverageは`PARTIAL`であり完全PASSとは記載しない。

重要: 実E220が32 byte以下のwriteでAUX LOW pulseを出さないこと自体はFAILではない。
logic analyzerで連続HIGH経路のwrite間隔が550 ms以上であることを確認する。LOWを一度でも
観測したwriteは、HIGH復帰後15 ms未満に完了または次writeしていないことを別に確認する。

### 6.1.1 公式仕様を反映したAUX契約と実測

EBYTEの[E220-900T22S製品ページ](https://www.ebyte.com/product/1085.html)から提供される
User Manualの5.6.2は、AUX HIGH時には内部400-byte bufferへ400 byte未満を連続投入でき、
AUX LOWはbuffer内容が無線chipへ未転送のbusy状態を示すと説明している。また、AUX HIGHでも
最後のpacketが無線送信中の場合があるとしている。

この記述からは、各32-byte UART write後に必ずAUX LOW pulseが発生するとは保証できない。
このためruntime契約は、全量write後もAUXが連続HIGHでもLOW→HIGHでも、full受付から
550 ms経過かつHIGH連続15 msでone-shot完了とする。550 ms以前の完了または次writeは
禁止する。dwell到達までにLOWを観測してもfull受付時刻をfloor起点として保持し、
その後HIGHが連続15 msになるまでbusyとする。LOWのまま、または
再HIGHできない状態が2 s続いた場合はfail-closeする。partial writeのfail-closeとzero writeの
同一suffix再試行契約は変更しない。

production HILではlogic analyzerで次を別々に判定する。

1. 自然な連続HIGH writeで、全量write完了時刻から次writeまで550 ms以上であること。
2. LOWが観測されたwriteで、LOW後のHIGH連続15 ms未満に次writeがないこと。
3. 故障注入でAUXをLOW固定した場合、2 s後に通常radio TXが停止すること。

実機負荷でLOWが一度も発生しなければ項目2のhardware coverageは`PARTIAL`と記録し、hostの
`FW-AUX-001`を補完証拠とする。LOW pulse非発生だけを理由にflashゲートを`BLOCKED`にはしない。

### 6.2 MAVLink主要経路

| Test ID | HIL構成 | 刺激と測定 | 基準 |
|---|---|---|---|
| `E2E-MAV-001` | 実Pixhawkまたはfixture→Ground raw | Pixhawk Heartbeat 1 Hzを60 s | 有効60/60、CRC error 0、最大gap≤2500 ms |
| `E2E-MAV-002` | Ground fixture→Pixhawk-side USB-UART | GCS Heartbeat 20 frame | D6側20/20、byte順序/hash一致、control漏れ0 |
| `E2E-MAV-003` | 実Pixhawk+Mission Planner | `PARAM_REQUEST_READ` 20回、応答capture | request/value 20/20、targetとparameter対応一致 |
| `E2E-MAV-004` | 承認済み非作動parameterまたはfixture | `PARAM_SET`→`PARAM_VALUE` 20回 | set/update/value 20/20。実Pixhawkでは元値へ復元しparameter diff 0 |
| `E2E-MAV-005` | 実Pixhawk+Mission Planner | `MAV_CMD_REQUEST_MESSAGE` 20回 | `COMMAND_LONG/ACK` 20/20。作動系command 0 |
| `E2E-MAV-006` | dual fixture | 両方向のwire size>32 frame | endpointで完全CRC frameのみ。E220 UART各write≤32 byte |
| `E2E-MAV-007` | dual fixture | payloadにraw `VCTD`を含むgolden fixture | 出力hash完全一致、control誤検出/漏れ0 |
| `E2E-MAV-008` | Pixhawk-side fixture | msg194 32 Hz＋Heartbeat 1 Hzを60 s | msg194 1920入力、Ground出力0、Heartbeat 60/60、最大gap≤2500 ms |
| `E2E-MAV-009` | Ground-side fixture | 35 byte `PARAM_SET`×17、計595 byte | 17 CRC、595 byte SHA-256=`3A378EDAA8F36C650B31A46C41DDBF079DCBF97E3526F13C1C0FCD9E773D8674`、drop 0 |
| `E2E-MAV-010` | Pixhawk-side fixture | Heartbeat観測後2周期停止し再開 | 各停止周期はnominal+1100 ms以内にGRANT、再開Heartbeat exact、deadlock 0 |

実Pixhawk試験とfixture試験は別evidence directoryへ保存する。同じIDでも
`endpoint=mission_planner`と`endpoint=fixture`を区別し、一方で他方を上書きしない。

## 7. flash前ゲート

以下がすべて揃うまでproduction firmwareを書き込まない。

1. host通常suiteがFAIL 0である。
2. CTest `phase5`が全PASSし、Heartbeat最大gapが2500 ms以下である。
3. CTest `phase6`が全PASSし、ASan/UBSan reportが0である。
4. Vehicle、Ground production sketchをXIAO ESP32-S3 FQBNで順番にcompileできる。
5. Ground production sourceからMission Planner USBへの`print/printf`が0である。
6. production sourceが`FixedFirmwareContract`のD0/D1/D2/D3/D6/D7/D8、57600、115200、
   `00 00 E5 C3 46 00 00 00`、32/50/180、3000/650/300/2000/650を使う。
7. Vehicle/Ground binaryとsource treeのSHA-256 manifestを生成済みである。
8. `hil_capture_serial.ps1`のsyntax checkと`hil_analyze_capture.py --self-test`がPASSする。
9. operatorが電源OFFで配線、3.3 V logic、E220 5 V、共通GND、アンテナを確認する。
10. 実Pixhawkを使う前にparameter backup、DISARMED、actuator隔離を確認する。

ゲート通過後も、一度に両側を書き込まない。最初はfixture構成でVehicle、次にGroundを個別に
書き込み、startup fail-closeを確認してから無線pair試験へ進む。

## 8. ユーザーに必要な操作

flash承認前にユーザーが提示する情報は次のとおり。

- 使用するVehicle/GroundのCOM番号
- XIAO ESP32-S3 2台の識別方法
- 3.3 V TTL USB-UARTの有無
- 115200 UART＋digital AUXを同時取得できるlogic analyzerの有無と機種
- Pixhawk機種、ArduPilot version、TELEM port番号
- Mission Planner `.tlog`保存先
- parameter backupファイル
- `E2E-MAV-004`を実Pixhawkで行う場合の承認済みparameter名と元値
- wiring写真と両側E220 profile readback

logic analyzerまたはPixhawk-side USB-UARTがない場合、内部session、AUX transition、
両方向exactnessは観測できない。その状態でPhase 6全体をPASSにはしない。
