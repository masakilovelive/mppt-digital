# VC_LoRa Pixhawk MAVLink Direct Bridge

R19のJev診断ゲート（PC側・Phase A shadow only）は
[`tools/jev_advisor/README.md`](tools/jev_advisor/README.md)を参照する。実機、COM、
ファームウェア、TDD、通信設定には接続しない。

このフォルダは、Pixhawk と Mission Planner を E220-900T22S LoRa で直接つなぐためのブリッジです。

現在の作業場所、R18実機合格値、R19高速化仕様、未解決課題、再開手順は
[`CURRENT_WORKSPACE_AND_SPEC_R19.md`](CURRENT_WORKSPACE_AND_SPEC_R19.md)を入口とする。

通常運用では `MAVProxy`、UDP、Route Monitor UI は使いません。Mission Planner は Ground 側 XIAO ESP32-S3 の USB COM ポートを直接開きます。

## R17 source・buildステータス（2026-09-13）

現行protocol version 2 canonical sourceのホスト試験はCTest runner **179/179**件が成功し、
論理結果は**177 normal PASS＋2 expected negative＋0 unexpected FAIL**である。expected negativeは旧方式の
不変条件違反と、transportと分離したRF schedule単体のHeartbeat SLAである。

R16のMission Planner 932件取得で1回だけ観測したHeartbeat間隔`2951.354 ms`に対し、
Ground USB pacerを固定2枠から3枠へ変更した。新しいtest-first再現では、空上り周期を跨ぐ
USB完了間隔を`2951 ms`から`2401 ms`へ短縮し、PARAM_VALUEのbyte-exact FIFO順序を維持する。
canonicalはproduction/diagnostic計4 Arduino sketchへ同期済みで、ESP32 core 3.3.11の
Vehicle→Ground clean compileもPASSした。R17 binaryのupload・COMアクセス・実機再試験は
未実施であるため、deployment判定は**NO-GO**である。

`ST-MAV-001`は本番MAVLink経路を10000周期通し、5 ms量子でheartbeat 49995 frame、
最大gap 1720 ms、GRANT/DONE 10000/10000を確認した。vehicle/ground streamの
exact rolling hashはそれぞれ`11334217462533280590` / `7893383440479344794`で、
queue drop、CRC、部分frame、制御漏れ、action retryは0である。非CTest補助ID
`ST-MAV-001-Q1`も1 ms量子で最大gap 1870 ms、同一hashとなった。canonical証拠は
`runs/ST-MAV-001/summary.json`と
`runs/diagnostics/ST-MAV-001-Q1/summary.json`にあり、summaryの`reproduce`は
`.\build\host\tests\host\vc_lora_host_tests.exe`を含む実行可能なコマンドである。

`ST-MAV-PHASE-001`はheartbeat位相0～999 msを全探索して6000周期を実行し、
基準超過0/1000、worst gap **1720 ms**だった。各位相でheartbeat停止2周期も完了し、
tail timeout、deadlock、予期しないdrop/retryは0である。Clang 22.1.8の
2026-08-25 target priority baselineもClang 22.1.8のASan/UBSan専用fresh buildで全167/167 PASSし、
ASan/UBSan/runtime-error markerは0だった。証跡は
`runs/validation/VEHICLE-TARGET-PARAM-PRIORITY-AUDIT-002/20260825T121001641Z/`に固定する。

修正前の2720 ms（5 ms量子）と2690 ms（1 ms量子）は、現行判定ではなく
fail-firstのRED証拠である。前者は
`runs/diagnostics/ST-MAV-001-pre-tail/{summary.json,trace.csv}`、後者は
`runs/diagnostics/archive/ST-MAV-001-Q1-legacy/diagnostic_summary.json`へ分離している。

`ST-003`はRF独立random corruption 3件とdecoder CRC error 3件を1:1確認し、
targeted corruptionは0だった。

Phase 6では、Mission Plannerのローカル`MAVLink.dll`と照合した80 msgid、固定scheduler、
16 KiB frame-atomic Ground ingress、local UART suffix retry、永続boot/session ID、64-bit単調時刻、
E220 write/AUX契約、profile fail-closeをArduino非依存coreへ実装した。Ground USB向け4 KiB
local egressは満杯時に新しく完成したMAVLink frame全体だけをdropし、TDD/radioを停止しない。
Vehicle→Pixhawk側は従来どおりoverflowをfail-closeする。80件は接続・操作・
parameter・command・mission・log系46件とtelemetry/status系34件であり、`SET_MODE`、manual/RC、
guided setpoint、log転送に加え、ArduPilot `PARAM_ERROR` (msgid 345、CRC extra 209、payload 21/21)を
urgentとして含む。`SYSTEM_TIME`と`TIMESYNC`は独立bucketで各1 Hzに制限する。

Vehicle schedulerは通常/urgent/heartbeat用の固定8 slotに加え、`PARAM_VALUE`専用の
1024-frame / 64-KiB generic FIFOと、D6で受理した`PARAM_REQUEST_READ`に一致する応答用の
固定8-frame target priority laneを持つ。index指定では未使用`param_id`をidentityに含めず、
target system/componentの0はMAVLink broadcast wildcardとして扱う。mixed ID/index overlapでは
Pending request ownershipをqueued duplicate判定より先に割り当てる。generic FIFOをdrop・並べ替えせず、
active frameもpreemptしない。

`IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001`はactual TDD controller、RF medium、
550-ms write gateを通し、RF #20→D6 admission→remember→旧18＋target＋1-Hz heartbeatを検証する。
exact SERIAL1_BAUD targetはrequest originから7614 ms（D6から2304 ms）でGroundへexact once到達し、
旧18件も39 cycle後にGround parserへbyte-exact FIFOで全件到達し、direction reverse quietは647 ms以上だった。target周辺RF heartbeat gapは1650 ms、
full-run RF最大gapは2959 msである。actual RF heartbeatはsequence/wire重複なしで、warm-up後の
全4到着spanが6200 ms以下（最大5159 ms）、すなわち3 unique/trailing 6200 msのpacer供給条件を満たす。
USB 2500-ms SLAはfull-run RF gapと分離し、この供給条件、Ground USB heartbeat
pacer/ordered-commit試験、およびR17の
`IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001`の合成を正本とする。

Vehicle/Groundの各スケッチフォルダはcanonical core source/headerと共通adapterのコピーを
同梱する形式である。R17 canonicalはproduction/diagnostic計4 sketchへ同期済みで、
production Vehicle/Groundはclean compile済みだが、R17 binaryは未書込みである。
外部`VC_LoRa_Core` libraryのインストールや追加指定は不要である。adapterはNVSへ非0の
boot/session IDを永続化・readbackし、
`esp_timer_get_time()`を64-bit単調時刻として使う。Ground native USBはMAVLink専用で、
debug文字列、独自binary record、synthetic heartbeatを出さない。

現行のTDD制御はprotocol version 2の**exact 32-byte** frameである。offset 0～19に
`VCTD`/header/payloadを保持し、offset 20～29は0 padding、offset 30～31はoffset 0～29を
対象にしたCRC-16/CCITT-FALSEである。Vehicleの650 ms `UplinkGuard`はGRANTのUART受付時ではなく、
GRANTが物理的にdrainした点Qをepochとして必ず全量650 msを確保する。

v2では上りMAVLinkを**1 GRANTにつき1 complete frame**に限定し、link-dataの物理writeを
32 byteへpaddingする。VehicleはCRC-validなcomplete frameとmatching `UL_DONE`の
session/cycle/actualが揃った場合のみatomic commitする。空cycleだけはexact32 `UL_IDLE`を使う。

300 msはwhole-frame transactionの承認／開始期限である。開始前にdescriptorの全wire長を
previewし、最初のprefixがAcceptedとなった後は同一descriptorのみ550 ms service-floor
pacingで窓外まで有界完遂し、その後`UL_DONE`を送る。64-wire frameは2 DATA＋DONEを
Vehicle receive timeout 2000 ms内に完了し、96-wire/oversizeはprefix 0の`UL_IDLE`とする。

通常受信timeout後は`late_terminal_wait_ms=1300`の絶対floorを設けたlate recoveryに入る。
回復中のraw radio活動はdeadlineを`raw_now + 650 ms`へ延長するだけで、1300 ms floorを短縮しない。
最大64 byteの上りtransactionは隔離bufferに保持し、CRC-validな完全MAVLink frameと同一
session/cycleのDONEが揃った場合のみD6/local egressへ**atomic commit**する。IDLE、CRC不正、
identity不一致、overflowはpayloadをcommitしない。有効DONE/IDLE後は固定650 msのpost-terminal guardに入る。
開始後のwriter不準備やwrite=0/Rejected反復は、最初のDATA Accepted時から2000 msの
絶対deadlineでruntime fail-closeする。partial DONE、suffixの次cycle/sessionへの持越し、再admissionは禁止する。

判定は二段階である。

- **Software / host preflight: GO** — host 179/179、production `E220WriteContract`を通す
  buffered transport、2-chunk continuation、watchdog、Ground USB heartbeat 3枠予備の契約試験がPASS。
- **Deployment: NO-GO** — R17 canonicalはArduino同期・clean compile済みだが、
  upload・COMアクセス・Mission Planner実機再試験は未実施である。
  Vehicle/Ground両方を完全電源再投入し、実機でHeartbeat最大gap <= 2500 ms、
  parameter read/write、CRC/partial/control leakage 0を再確認するまで運用GOにしない。

固定通信値3000/650/300/2000/650 ms、32-byte write、180 ms minimum lower bound、ピン、UART、
E220 profileは変更していない。HIL観測に基づく550 ms remote service floorをruntimeに追加した。

従来のVehicle/Ground binary SHA-256
`445545EEC6DE0CCED1A3105D539D80C77C6612A078CE52900218AF6939F88C3D` /
`C7778087E42D546662C10D7F2415298920C6FFCDA2BE87D769E9FDD249F1798B`は**550 ms service-floor変更前の
履歴build**であり、現行canonical sourceのcompile/書込み証拠として扱わない。

現行compileの不変証拠は`runs/validation/final_production_compile_20260823T192757014Z/`に固定した。
Vehicle appは391952 byte / SHA-256
`4431DCB13DF662F91413700A8B2EFFE2F6A9E2A03473B6C3419C9C6C7CDBFC86`、Ground appは364144 byte /
`095C9BE529DFA24A544CAE544801B9E5D702CB181AFB87DBBD6DC62DAE334BCB`である。source treeは
`B835173B1AA3837CEBDB94F1F0AEBFBC682EA0084E6A5E7D41F0C134DD2EE2D6`、manifestは
`BBE61DE437D8E624A8016A53AAFC72C43B5C12ED9038C54FFEE72B7393EB56E0`で、`flash_performed=false`である。
このcurated appをVehicle COM3→Ground COM6順に標準4領域へ書き込み、各roleでMAC一致、
hash verify 4/4、hard reset、同一PNP再列挙を確認した。書込み証拠は
`runs/hil/PROD-V2-PACING-HB-UPLOAD-001/20260823T194053048Z/`にある。

## 接続構成

```text
Pixhawk TELEM
  <-> Vehicle XIAO ESP32-S3
  <-> Vehicle E220-900T22S
  )) 920 MHz LoRa transparent link ((
Ground E220-900T22S
  <-> Ground XIAO ESP32-S3
  <-> PC USB COM
  <-> Mission Planner
```

## 使用ファイル

| ファイル | 用途 |
|---|---|
| `vc_lora_vehicle_xiao_esp32s3/vc_lora_vehicle_xiao_esp32s3.ino` | Pixhawk側Phase 6 production wrapper |
| `vc_lora_ground_xiao_esp32s3/vc_lora_ground_xiao_esp32s3.ino` | PC/Mission Planner側Phase 6 production wrapper |
| `firmware/phase6/vc_lora_phase6_bridge.hpp` | 両role共通の固定Arduino adapter |
| `vc_lora_{vehicle,ground}_xiao_esp32s3/{VC_LoRa_Core.h,vc_lora_phase6_bridge.hpp,vc_lora/,src/}` | Arduino IDE直開き用copy（R17 canonicalと同期・production clean compile PASS、R17未書込み） |
| `tools/sync_arduino_sketch_core.ps1` | canonical core/adapterを両スケッチへ明示同期する開発用スクリプト |
| `vc_lora_bridge_xiao_esp32c3/vc_lora_bridge_xiao_esp32c3.ino` | 過去のC3切り分け用legacy実装 |
| `vc_lora_ground_e220_diag_xiao_esp32s3/vc_lora_ground_e220_diag_xiao_esp32s3.ino` | E220 設定確認・変更用の診断コード |
| `vc_lora_usb_serial_smoke_xiao_esp32s3/vc_lora_usb_serial_smoke_xiao_esp32s3.ino` | XIAO USB Serial 単体確認用 |

`xiao_esp32c3` 系フォルダは過去検証・参照用です。production対象はXIAO ESP32-S3です。

## 通信設定

| 区間 | 設定 |
|---|---|
| Mission Planner -> Ground XIAO USB COM | `57600 bps` |
| Ground XIAO <-> Ground E220 | `115200 bps` |
| Vehicle E220 <-> Vehicle XIAO | `115200 bps` |
| Vehicle XIAO <-> Pixhawk TELEM | `57600 bps` |
| E220 UART format | `8N1` |
| E220 air data rate | `19.2 kbps` |
| E220 sub-packet / bridge chunk | `32 bytes` |
| E220 周波数 | 920 MHz 帯、両側同一チャンネル |
| E220 動作モード | Transparent / Normal |

現在確認している E220 設定例:

| 項目 | 値 |
|---|---|
| ADDR | `0x0000` |
| REG0 | `0xE5` |
| UART baud | `115200` |
| UART format | `8N1` |
| Air data rate | `19.2 kbps` |
| REG1 | `0xC3`（32-byte、10 dBm） |
| REG2 | `0x46` |
| 周波数 | `920.125 MHz` |
| REG3 | `0x00` |
| CRYPT | `0x0000` |

`REG0=0xC8` は使用しません。`0xC8` は 57600 / 8O1 / air 2.4 kbps であり、
固定UART条件の `SERIAL_8N1` と一致せず、Pixhawk の連続 MAVLink 帯域も不足します。

### E220 固定設定・確認

両側の E220 を1台ずつ設定します。

1. XIAO ESP32-S3 に `vc_lora_ground_e220_diag_xiao_esp32s3.ino` を書き込む。
2. USB Serial Monitor を `115200` で開く。
3. `r` を送り、現在の全レジスタと `UART` / `AIR` のデコード結果を確認する。
4. `5` を送り、固定プロファイルを永続書込みする。
5. `[PROFILE] PASS` と `REG0=0xE5`、`REG1=0xC3` が表示されることを確認する。
6. もう一方の E220 でも同じ操作を行う。

固定プロファイルは `00 00 E5 C3 46 00 00 00` です。両側で完全一致させます。
Phase 6 production firmwareは起動時にこの8バイトを読み、相違する場合だけ永続設定を
書き直して再読出しする。読出し、書込み、再検証、またはboot/session永続化に失敗した場合は
通常modeの無線送信を開始しない。

E220への各物理writeは32 bytes以下でall-or-nothingとする。zero writeは同じsuffixを再試行し、
partial writeはfail-closeする。E220公式の400-byte内部buffer仕様では各write後のAUX LOW pulseは
保証されない。最新HILで観測した32-byte remote service間隔550 msを固定floorとし、AUXが
連続HIGHでもfull writeから550 ms未満では完了させない。途中でLOWを観測した場合も元のfull
write時刻をfloor起点として保持し、550 ms経過かつ再HIGH連続15 msまでbusyとする。LOWが2 s
継続すればfail-closeする。550 ms floorはremote service spacingを保つための値であり、内部bufferが
完全に空になったことを保証する値ではない。
ホストbuffered modelはUART約3 ms後に550 ms air serviceを開始するため、次write受理時に最大
64 byteが短時間共存する。これは累積せず、remote completion間隔550/551 ms、方向転換quiet
654 ms（要求500 ms以上）を`IT-E220-BUFFERED-UPLINK-001`で確認済みである。
また、最初のDATA Accepted後は2000 msの絶対deadlineを設け、writer不準備、zero-write拒否、
newer-session rebootでsuffixを流用できない場合は、partial DONEを出さずruntime fail-closeする。
deadlineと同時に既観測のradio completionはtimeoutより先に受理し、future-write capacityはその
completion判定に使わない。`UT-GROUND-BOUNDED-CONTINUATION-001`がこの契約を固定する。

`partial_flush_ms=50`は旧raw-byte stagingが32 bytes未満を保持できる最大待ちを固定する互換定数で
あり、Phase 6 production pathのtimer判断には未使用である。frame-aware経路はCRC合格済み完全frameだけをqueueし、active frameの32 bytes未満の
tailを別の50 ms timerで保持せず即時eligibleにする。このlocal staging待ちは0 ms、したがって
50 ms以内だが、TDD admission windowと550 ms service-floor pacingによる実送信待ちは別である。

TDD controlは明示UL_DONEを持つversion 2、exact 32 byteである。offset 20～29のreserved paddingはすべて0、
offset 30～31のCRCはoffset 0～29に対するCRC-16/CCITT-FALSEとする。decoderは32 byte以外を
有効controlとして受理しない。旧形式candidateは混在streamのresync時に隔離するだけで、
現行controlとしてはdecodeしない。

E220単体試験では送受信方向の切替に500 ms以上必要だったため、productionコードは
5秒周期の半二重TDD制御を使用します。Vehicleは3.0秒間だけPixhawkデータを
送信し、その後2.0秒間はE220への送信を停止してGroundデータを受信します。
GroundはVehicleデータが停止して650 ms後の300 ms内に新しいwhole-frame transactionを
承認・開始します。開始済みの同一descriptorは、窓を超えても550 ms pacingで全DATA＋DONEまで
有界完遂します。新規frameは300 ms境界以降に開始しません。
これによりGround送信の前後へ500 ms以上の無送信時間を確保します。

過去のE220単体試験では1パケット往復処理に約164 msを観測したため、180 msは
32-byte write開始間隔の下限として保持します。最新HILのremote service間隔550 msを受け、
production runtimeでは550 ms service floorの方が実際の再writeを制限します。また、対象Pixhawkが
`msgid=194`などの高頻度テレメトリで回線を占有していたため、Vehicle側は
MAVLinkを完全なフレーム単位で解析します。heartbeatは専用優先スロットへ、
コマンド・ミッション・パラメータ応答は8フレームキューへ格納します。
姿勢・GPS・電源・EKFなどの表示用テレメトリは1 Hzに制限し、それ以外の
低優先度フレームは破棄します。

v1.6のproduction coreでは、CRC合格済みの実Heartbeatを一度観測した後だけ、Vehicleの
3000 ms nominal境界を起点に最大1100 msのheartbeat tailを有効にします。実Heartbeatの
選択は通常frameと分離し、選択後もscheduler上で利用可能な同一frameだけをAUX安定・
物理write準備完了後に送信します。Rejected、signed MAVLink 2、escapeによる複数writeでも
同一frameを正確に完了し、通常frameをtailとして誤送信しません。このcoreをVehicle/Ground
production wrapperが直接使用します。

直接証拠は`UT-MAV-BOUNDARY-003`～`008`（no-HB、inclusive endpoint、busy、
availability消失、signed/escape/Rejected、AUX 15 ms）と、`E2E-MAV-010`
（Heartbeat停止2周期→有界GRANT→tail再開）で、すべてPASSしています。

## ピン配置

### XIAO ESP32-S3 <-> E220

| XIAO | E220 | 内容 |
|---|---|---|
| `D0` | `M0` | E220 mode 0 |
| `D1` | `M1` | E220 mode 1 |
| `D2` | `RXD` | XIAO TX -> E220 RX |
| `D3` | `TXD` | XIAO RX <- E220 TX |
| `D8` | `AUX` | E220 AUX |
| `GND` | `GND` | 共通GND |

### Vehicle XIAO ESP32-S3 <-> Pixhawk TELEM

| XIAO | Pixhawk TELEM | 内容 |
|---|---|---|
| `D6` | `RX` | XIAO TX -> Pixhawk RX |
| `D7` | `TX` | XIAO RX <- Pixhawk TX |
| `GND` | `GND` | 共通GND |

## Pixhawk パラメータ

TELEM1 を使う場合:

| パラメータ | 値 |
|---|---|
| `SERIAL1_PROTOCOL` | `2` |
| `SERIAL1_BAUD` | `57` |
| `SERIAL1_OPTIONS` | `0` |
| `BRD_SER1_RTSCTS` | 要求`0`／現行read-only値`2` (Auto) |

TELEM2 を使う場合は `SERIAL2_PROTOCOL`、`SERIAL2_BAUD`、`SERIAL2_OPTIONS` を同じ考え方で設定します。
現行のread-only取得値はSERIAL1/2_PROTOCOL=2、BAUD=57、OPTIONS=0、MAV1/2_OPTIONS=0、
BRD_SER1/2_RTSCTS=2 (Auto)である。RTSCTSの要求値0と実機値2の不一致はD6→flight-controller境界の
次回切り分け対象とし、この文書更新ではparameter mutationを行っていない。

## Phase 6 controlled HIL書き込み手順

以下は[HIL_TEST_PLAN.md](HIL_TEST_PLAN.md)のflash前ゲート、binary/source manifest、電源OFF配線、
アンテナ、3.3 V logic、Pixhawk安全確認を満たした場合だけ実施する。この手順が記載されている
こと自体はdeployment承認を意味しない。R17 canonicalは4 sketchへ同期し、production
Vehicle/Groundをclean compile済みだが、R17 binaryは未書込みである。
Heartbeat SLAおよび932件parameter往復HILが完了するまでdeploymentはNO-GOである。
修正前からArduino IDEで対象スケッチを開きっぱなしの場合は、いったん閉じてから対象`.ino`を
再度開き、同梱ファイルをIDEへ再認識させる。

1. `vc_lora_vehicle_xiao_esp32s3`フォルダ全体を保持したまま、その中の`.ino`をArduino IDEで開き、
   Vehicle 側 XIAO ESP32-S3へ書き込む。
2. `vc_lora_ground_xiao_esp32s3`フォルダ全体を保持したまま、その中の`.ino`をArduino IDEで開き、
   Ground 側 XIAO ESP32-S3へ書き込む。
3. Arduino Serial Monitor、Route Monitor UI、MicoAssistant など、対象 COM を開いているアプリを閉じる。
4. Ground 側 XIAO を PC に接続する。
5. Mission Planner で Ground 側 COM を選び、`57600` で接続する。

成功判定は「ハートビートを1回だけ受信」ではなく、Mission Planner が継続して heartbeat を受信し、パラメータ読み込みが進むことです。
加えて、Ground COMを開かない状態を旧不具合検出時の約112秒以上維持してから、XIAOを
再起動せずMission PlannerでCOMを開く。保持済み完全frameがFIFO順に再開し、その後の
heartbeat/parameter通信とTDDが継続することを確認する。

## 別PCで使う場合

コード内に PC 固有の COM 番号や IP アドレスは固定していません。

必要なもの:

| 項目 | 内容 |
|---|---|
| Arduino IDE | `2.3.7`で検証済み |
| ESP32 board core | `3.3.11`固定（HWCDC TX欠落・停止修正を含む） |
| Board | `XIAO_ESP32S3` |
| USB Mode | Groundは`Hardware CDC and JTAG`必須 |
| USB CDC On Boot | Groundは`Enabled`必須 |
| ドライバ | 必要に応じて CP210x / USB CDC ドライバ |
| Mission Planner | Ground XIAO の COM を `57600` で直接接続 |

各`.ino`だけを別フォルダへ移動しないでください。`VC_LoRa_Core.h`、`vc_lora_phase6_bridge.hpp`、
`vc_lora/`、`src/`を含むスケッチフォルダ全体が必要です。外部`VC_LoRa_Core` libraryは不要です。
別PCへ移す場合もArduino IDEの`File`→`Save As`は使わず、Explorer等でスケッチフォルダ全体を
コピーしてください。
canonical core/adapterを変更した開発者だけが`tools/sync_arduino_sketch_core.ps1`を明示実行し、
contractのSHA-256一致を確認します。

COM 番号は PC ごとに変わります。Mission Planner では、その PC に表示された Ground XIAO の COM を選択してください。

## 切り分け

| 症状 | 確認 |
|---|---|
| COM が開けない | Arduino Serial Monitor や他アプリが同じ COM を開いていないか確認 |
| heartbeat が1回だけ | 無線は一部通っているが連続通信が不安定。E220電源、アンテナ、距離、TELEM baud を確認 |
| heartbeat が全く来ない | Pixhawk TELEM TX/RX/GND、E220 両側設定、Mission Planner baud を確認 |
| Ground COMをしばらく開かなかった後だけ接続不能 | 実機binaryがcanonical hashと一致するか確認し、USB未接続→再接続HILを実施 |
| Serial raw は来るが valid frame がない | baud 不一致、デバッグ文字列混入、E220固定送信モード、TELEM設定不一致を確認 |
| 単純な無線文字列は通るがMAVLinkが通らない | 両側の `REG0=0xE5`、`REG1=0xC3`、8N1、air 19.2 kbps、AUX配線を確認 |
| E220 AUX が LOW のまま | 電源不足、E220 busy、AUX配線、モジュール不良を確認 |

## Phase 6統合コードの確定方針

- MAVLink 経路にはデバッグ文字列を出しません。
- テスト heartbeat は出しません。
- Mission Planner は Ground XIAO COM に直接接続します。
- MAVProxy / UDP / Route Monitor UI は通常運用から外します。
- E220は半二重TDD（Vehicle TX 3.0秒 / RX 2.0秒）で運用します。
- 固定設定の検証に失敗した場合は送信を開始しません。
- 80 msgid、scheduler/backpressure、session/time/AUX/write/profile契約をhost testで固定しています。
  target priority版core/adapterのArduino copy同期は未実施です。
- Ground USB未接続中に4 KiB local egressが満杯になった場合は、新しく完成したframe全体を
  drop-newestとして診断し、TDD/radioを継続します。Vehicle側の同じoverflowはfail-closeです。
- software/preflightとTDD terminal recoveryはPASSです。変更前v2 production HILはmsg22=0、Heartbeat最大gap
  4098.309 msでした。現行binaryのparameter read/write再実測とHeartbeat SLAがPASSするまでdeploymentはNO-GOです。

## E220単体リンク試験

PixhawkやMission Plannerの連続通信を除外して無線部分だけを確認する場合は、
次の2本を使用します。USBシリアルモニタは両側とも115200 baudに設定します。

- 車載側: `vc_lora_e220_link_test_sender_xiao_esp32s3`
- 地上側: `vc_lora_e220_link_test_receiver_xiao_esp32s3`

車載側はCRC付き32-byte DATAを送信します。地上側は正常なDATAを受信後、
連番に応じて300 / 500 / 700 / 1000 ms待ってから32-byte ACKを返信します。
`[LINK_RX] valid/missing/crc_err`で上り品質を、`[LINK_TX]`の
`d300` / `d500` / `d700` / `d1000`で各遅延の送信・ACK・timeout・RTTを
確認できます。両ファームは
起動時にE220を固定`E5/C3`プロファイルへ自動設定・検証します。
