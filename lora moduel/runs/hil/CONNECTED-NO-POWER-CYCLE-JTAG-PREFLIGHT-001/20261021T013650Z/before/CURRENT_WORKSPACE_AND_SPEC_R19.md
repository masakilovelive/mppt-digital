# VC LoRa Bridge 現行作業場所・仕様・進捗（R19）

最終更新: 2026-10-21 JST  
対象: VC LoRa Bridge R18低速製品版とR19高速転送候補  
目的: 作業場所、固定仕様、実測済み結果、30秒目標、未解決事項、再開手順を一つの入口にまとめる。

## 結論

- 最新のオフライン再検証と再発履歴照合はSection 31.59である。受信0 byteの症状はR18／R19とも過去にあり、新規症状ではない。ただし今回の原因が過去と同じと判明したわけではない。受信準備272項目・境界判定54項目をPS5.1／7で再PASS、関連21/21及び通常版build2/2もPASS。機器ARM／初回enqueue固定記録とmode別実機手順は未統合で、実機操作はしていない。
- 最新の接続状態確認はSection 31.58である。外出中の利用者から検証依頼を受け、COM6を57600 bps・DTR/RTS falseで60秒間受信のみ観測した。COM3／COM6及び両USB-JTAG等のOS認識は正常だが、受信0 byte／送信0 byteで、現在の下り通信は確認できなかった。書込み・JTAG・reset・要求送信は行っていない。これはR19比較試験ではなく、機器上のfirmware hash・Pixhawk通電・RF・初回USB停止の原因も未確定である。
- 連続Readと機器側HostArmの土台はSection 31.55である。PC側の物理Read担当をCOM Openからcleanupまで単一の連続readerとし、identity確認後の担当切替えを廃止した。同節時点で全host343/343、include経路の限定修正後49/49、通常／診断Arduino4/4ビルドはPASS。最新のオフライン追加はSection 31.57を参照する。106 ms、UART／TDD／E220設定及び既存sealed候補は未変更。機器HostArmの診断source／codecは準備済みだが、能動live runnerとmode別candidate／flash bindingは未統合で、既存passive試験へは使用しない。
- 最新のR19診断版実機結果はSection 31.56である。同じ候補 `20261020T123447347Z-b414028b` を1回評価し、40秒で各2,646 byte／完全診断42 frame（測定内40＋startup 2）、全parser異常0を取得した。連続native Readの最大間隔はVehicle 57.4314 ms／Ground 57.4311 msで100 ms以内だが、LIVE解析処理は303.612／268.557 msで未合格。Groundの初回21-byte製品Heartbeatは今回も106 msのLoopTimeout、ring／stash 0、publish 3／pickup 2で失敗した。最初のReadの初期bufferに既に完全R19Fが63 byteあったため、この失敗が後続の解析遅延だけで起きたとは説明できない。PC Open前後の数値時刻・物理host pollingとの因果は未確定。両機accepted R18へのdigest照合付き復旧はPASS、今回の1回許可は使用済み、追加実機試験はしていない。
- Section 31.57では②の適応的混雑制御を`SPEC.md`の将来仕様`FUTURE-FLOW-001`へ分離し、①受信準備・③完了境界の切分け用offline workflow／判定器を追加した。実機runner／新しいmode別candidate／機器ARM記録は未統合で、現候補の書込みやCOM／JTAG操作は行っていない。既存実機データはUSB完了失敗を確認できる一方、受信準備との原因分類はUNKNOWN、RF／全パラメータはNOT_EVALUATEDのままとする。
- Section 31.48までのoffline準備は全host321/321・通常版／診断版ビルド・4記録の独立照合に合格済みである。Section 31.49では全16 rawの取得も成功したが、PC service gap及びUSB完了評価は未合格。932件30秒、Heartbeat最大2,500 ms及び製品Deploymentは未証明である。今回の実機一回限定許可は使用済みであり、追加試験はしていない。
- 最新のSection 31.43では、試験runnerの起動表示判定・timeout診断・初回処理負荷を修正し、cold boot後のR18単一PARAM実機試験に合格した。`SERIAL1_BAUD=57`の応答1件、要求→応答`5,297.170 ms`、Heartbeat最大`2,113.785 ms`、PC側pump最大`82.282 ms`、全parser／CRC／noise／partial／control leak 0である。前回の0 byteは再現しなかったが根本原因は未確定であり、今回の結果を全932件再取得又はR19高速受入へ拡張しない。
- R18低速製品経路は、Mission Planner実機試験で`PARAM_VALUE`を正確に932/932件取得し、同じ受入区間のHeartbeat最大間隔`2,206.203 ms`も基準`2,500 ms`以下で合格している。
- R18の全取得時間は`6,045.839 s`（`100.764 min`）であり、通信成立と完全性は確認済みだが高速ではない。
- R19は、同じE220プロファイル（air `19.2 kbps`、32-byte sub-packet）のまま、932件をGround USB上で`30,000 ms`以内に完了させる実験候補である。
- R19高速経路はaccepted R18 production bridgeへfeature-gate付きで統合済みである。既定値は`VC_LORA_R19_HIGH_SPEED_CANDIDATE=0`で、通常製品版の挙動は変更していない。
- Section 29後に、空の`IN_EMPTY`だけでCDC readyを成立させないpayload-pickup witnessと、CDC無出力でもJTAGから読める68-byte runtime stage recordを診断macro限定で統合した。normal／fresh ASan＋UBSanはいずれも303/303、診断ON／OFFのVehicle／Ground compile、HWCDC semantic、installer、candidate verifierに合格済みである。Section 31ではJTAG USB-openの直接blockerを分離し、R19書込み前に必ず停止できるpre-flash gateを追加した。
- R19診断版は2026-09-30に2回application-onlyで書込み、両回ともdual-COMが0 byteの`FAIL_NO_DIAGNOSTIC_BEACON`となった。各試験後に両XIAOをaccepted R18へreadback付きで復旧した。
- 2026-10-03に旧bootstrap修正済み診断候補を実機へ書き込んだが、3回目も両COMが0 byteだった。従って旧修正は実在するoffline bugを閉じたが、実機0 byteの十分条件ではなく、共通原因を確定したという旧記述は撤回する。
- 診断macro限定のfalse-SOF許容と明示的empty-FIFO/ZLP kickを含むfresh candidate `20261003T091702033Z-e3aa5200`も、2026-10-03にapplication-onlyで実機へ書き込んだが、4回目の40秒取得も両COMが0 byteの`FAIL_NO_DIAGNOSTIC_BEACON`だった。従ってこの修正もoffline上の欠陥を閉じたが、実機0 byteを解消する十分な物理修正ではない。
- 上記の追加診断を含むsealed candidateは`20261003T110913332Z-04fb913b`である。Vehicle／Groundのapp-only BINと同一buildのELF、map、build options、sdkconfig、partitions.csv、flash_argsを封印し、app offset `0x10000`と全hashを独立検証した。Section 30作成時点では未書込みだったが、その後Section 31の一回限定HILで書込み済みであり、両COM 0 byte、JTAGはCPU attach前に失敗し、最後にaccepted R18へ復旧した。
- R19のMission Planner＋Pixhawk＋E220による30秒実測は未合格である。したがって`physical_30s_proven=false`、`live_flash_authorized=false`を維持する。
- 2026-10-10のSection 31.16一回限定HILでは、Vehicle `COM3 / 1-3.4`、Ground `COM6 / 1-3.2`でactive JTAG、R19診断版install、40秒dual-COM、両roleの68-byte runtime-stage読取り、accepted R18復旧を完走した。dual-COMは両方0 byteだったが、両runtime-stageは`WriteAccepted`まで到達後、共通して`FlushFailed (0x54520010)`を最初の失敗として記録した。従って当該runの直接障害境界はMission Planner／MAVLink／E220 RFではなく、R19診断版のUSB CDC送信完了待ち経路である。JTAG cleanupは各CPUの`running`とshutdownを明示証明し、両XIAOはreadback付きでaccepted R18へ復旧済みである。詳細はSection 31.16を正本とし、最新結果はSection 31.23を正本とする。
- Section 31.16と整合するsoftware liveness gapとして、63-byte frameをsoftware ringへ受理した後の最初の実payload FIFO投入がempty-FIFO/ZLPと後続`IN_EMPTY`に依存する点を特定し、診断macro限定で最大32 byteを直接FIFOへprimeするtest-first修正を完了した。これはoffline修正候補であり、実機0 byteの根本原因確定又は解消済みを意味しない。通常製品経路、`flushTxComplete()`の成功条件、UART／TDD／E220設定は未変更で、accepted R18も未変更である。詳細はSection 31.17を正本とする。
- fresh candidate `20261010T090523384Z-93c6076d`を用いた次の一回限定HILは、両roleのactive JTAG preflight後、candidate install前の競合process検査で停止した。親`pwsh.exe`の起動コマンドに含まれた`COM3`／`COM6`を子flash toolが外部clientと誤認したことが十分原因である。candidate／R18の書込み、COM open、capture、stage readは0であり、全電源5秒以上OFFによる封じ込めも完了した。祖先processの限定除外をtest-firstで修正し、offline 303/303とVehicle→Ground compileはPASSしたが、実機再評価は未実施である。詳細はSection 31.18を正本とする。
- Section 31.20で追加し、Section 31.21／31.23の実機証拠に使用した固定96-byte／24-word Endpoint FIFO recordはschema 1の履歴ABIとして保持する。現行diagnostic ABIはSection 31.24のschema 2、固定112-byte／28-wordで、既存68-byte runtime-stageとreader-v3により読む。両XIAOのaccepted R18、UART／TDD／E220設定、`live_flash_authorized=false`は変更していない。
- Section 31.21の一回限定実機試験で96-byte recordを両roleから安定取得した。両roleともnonzero FIFO write、`WR_DONE`、raw `IN_EMPTY`、payload pickup、publish=pickup、pending 0を証明したが、40秒dual-COMは両方0 byteだった。Vehicleはflush success 1／timeout 1、Groundはsuccess 0／timeout 5である。従ってEndpoint FIFO未書込みは否定され、未解決境界はdevice-side payload pickup後からWindows user-space CDC受信前までへ狭まった。診断runはaccepted R18へreadback付きで復旧済みである。
- Section 31.22で、実機会計と一致する`flushTxComplete()`の最終ZLP再発行raceを特定し、最終flush発行後はZLPを再発行せずTX割込みのみ再有効化する最小修正をtest-firstで実施した。決定論モデル44/44、HWCDC契約、installer移行契約、Vehicle→Groundの製品版／診断版compile・seal・verifyはPASSした。この修正の実機結果はSection 31.23を正本とし、accepted R18と`live_flash_authorized=false`は維持する。
- Section 31.23でSection 31.22修正後の診断候補`20261011T141348202Z-34b9e8b0`を一回限定で実機評価した。COM3は0 byte、COM6は21-byteの有効なMAVLink2 HEARTBEAT 1件だけを受信し、診断beaconは0件だった。VehicleはFIFO 63 byteを全てpickupした後もflush 5/5 timeout、GroundはFIFO 84 byte、flush success 1／timeout 2で`GroundBoundaryImpossible`を記録した。従って最終ZLP再発行抑止だけでは継続通信を回復できず、CDC完全停止仮説も否定された。outerのPASSは証拠取得とaccepted R18復旧の成功であり、R19通信PASSではない。
- Section 31.24でzero-write／BUS_RESET／late `IN_EMPTY` raceとstale flush-success再利用を閉じ、record-owned flags bit 11 `PayloadPublishPending`、bit 12 `PayloadPublishAborted`、bit 13 `PayloadFlushPending`を追加した。known flag maskは`0x00003FFF`。reader schemaは`vc-lora-r19-runtime-stage-jtag-read-v3`で、68-byte runtime-stage＋112-byte Endpoint FIFO recordを各2回読み、last-event BUS_RESET、pending／aborted publication、pending flush、decoded flags不一致をfail-closedにする。fresh Clang 22.1.8 full host suiteはbuild 115/115、CTest 304/304、internal 275 PASS＋expected XFAIL 2＋FAIL 0である。本作業はoffline-onlyで、R19の実機効果は未証明である。
- Section 31.30の最新HILでは両COM 0 byteのままだったが、JTAG recordにより原因を二つへ分離した。Vehicleは63 byteを`32+31`で全てpickup後、31-byte short packetに不要なterminal ZLPを要求して`FifoNotWritable`待ちとなった。Groundは最初の63 byteを全てpickup後、clean-idleで後から積まれた21 byteをendpointへ再primeできず`SoftwarePending`となった。これはR19 USB CDC完了／再起動処理の問題であり、MAVLink、E220 RF、TDD又はUARTの障害証拠ではない。試験後はaccepted R18へ復旧し、一回限定許可は消費済みである。
- Section 31.31で上記2原因をtest-firstで修正した。既知の1..63-byte final packetはZLPなしで完了し、clean-idle enqueueはtask側から最大32 byteを直接primeする。zero／partial write、BUS_RESET前後、late-reset quarantine、R18 macro-off互換を保持した。完全版ClangでCTest 305/305、JTAG reader 115/115、通常Vehicle→Ground compile、診断候補`20261012T112913347Z-ee4f241c`のbuild／seal／独立verifyがPASSした。ただし本節はoffline-onlyで、R19実機修復、30秒受入及びDeploymentは未証明である。
- Section 31.38でaccepted R18再証明toolingの独立監査はP0／P1とも0でPASSした。そのtoolによる一回限定live runは、Vehicleのfull-length read-flashが`102400 / 389280 bytes`で終了し、esptool exit `255`となった時点でfail-safe停止した。Vehicleのexact USB role再列挙は証明されたが、erase／firmware writeは0、Groundは未操作であり、本runでは両roleともaccepted R18を証明していない。一回限定許可は消費済み、`power_off_required=false`、R19 acceptance／DeploymentはNO-GO継続である。

この文書は現在位置と仕様への入口である。値が食い違う場合は、実装定数、最新の封印済み実測証拠、個別仕様書の順に確認し、差異を解消するまで実機へ書き込まない。

## 1. 正式な作業場所

VC LoRa Bridgeの実作業ルートは次である。

```text
E:\VESC\TRIAL_LOG\Loreley3_System\06_vc_lora_bridge
```

セッション開始時のカレントディレクトリが別のCドライブを示す場合でも、VC LoRa関連の読取り、編集、ビルド、試験は上記ディレクトリを明示して実行する。

| 場所 | 役割 |
|---|---|
| `core/include/vc_lora/`, `core/src/` | Arduino非依存のcanonical core |
| `firmware/phase6/` | R18標準Phase 6 Arduino adapter |
| `firmware/high_speed/` | R19高速転送候補。現在は実験・オフライン範囲 |
| `vc_lora_vehicle_xiao_esp32s3/` | Vehicle production sketch copy |
| `vc_lora_ground_xiao_esp32s3/` | Ground production sketch copy |
| `tests/host/` | ホスト単体・統合・契約試験 |
| `tools/` | 同期、ビルド、HIL取得、解析ツール |
| `runs/` | 試験証拠。source treeとして編集しない |
| `build/` | 再生成可能なビルド出力。仕様の正本にしない |

## 2. システム構成

```text
Mission Planner
    | USB CDC / MAVLink 57600 bps
    v
Ground XIAO ESP32-S3
    | UART 115200 bps, 8N1
    v
Ground E220
    )) 920.125 MHz / transparent half-duplex link ((
Vehicle E220
    | UART 115200 bps, 8N1
    v
Vehicle XIAO ESP32-S3
    | TELEM MAVLink 57600 bps, 8N1
    v
Pixhawk
```

Mission PlannerはGround XIAOのUSB COMを直接開く。MAVProxy、UDP `14550`/`14555`、Route Monitor UI、ブリッジ生成の擬似Heartbeatは使用しない。

## 3. 固定ハードウェアと配線

### 3.1 XIAO ESP32-S3とE220

| XIAO | E220 | 方向・用途 |
|---|---|---|
| `D0` | `M0` | 動作モード選択 |
| `D1` | `M1` | 動作モード選択 |
| `D2` | `RXD` | XIAO TX → E220 RXD |
| `D3` | `TXD` | XIAO RX ← E220 TXD |
| `D8` | `AUX` | busy／drain観測 |
| `GND` | `GND` | 共通GND |

### 3.2 Vehicle XIAO ESP32-S3とPixhawk TELEM

| XIAO | Pixhawk | 方向 |
|---|---|---|
| `D6` | `RX` | XIAO TX → Pixhawk RX |
| `D7` | `TX` | XIAO RX ← Pixhawk TX |
| `GND` | `GND` | 共通GND |

Pixhawk USBはMission Plannerとの通常運用経路には必須ではない。直接比較、設定確認、診断取得時だけ使用する。Pixhawk本体とTELEM UARTには適切な外部電源と共通GNDが必要である。

### 3.3 E220型式表記の未解決差異

- [`SPEC.md`](SPEC.md)と現行READMEは`E220-900T22S`を対象としている。
- 過去のブロック図には`E220-900T30D`表記がある。
- 読取り済みversion `0x20`だけでは物理型式を一意に特定できない。

したがって、現在のプロファイルを変更せずに試験を継続する。送信出力、air rate、電源条件を変更する前に、両モジュールの印字ラベルとBOMを確認する。型式未確定は現行プロファイルでのR18実績を無効にはしないが、別プロファイルへの変更許可には使用できない。

## 4. 固定通信設定

| 区間・項目 | 現行値 |
|---|---:|
| Mission Planner ↔ Ground USB COM | `57600 bps` |
| Vehicle XIAO ↔ Pixhawk TELEM | `57600 bps`, `8N1` |
| XIAO ↔ E220 UART | `115200 bps`, `8N1` |
| E220 air data rate | `19.2 kbps` |
| E220 sub-packet／bridge chunk | `32 bytes` |
| RF channel／周波数 | `0x46`／`920.125 MHz` |
| E220 mode | Normal transparent |
| E220 profile | `00 00 E5 C3 46 00 00 00` |
| ADDH／ADDL | `0x0000` |
| REG1 | `0xC3`（32-byte、文書上10 dBm） |
| REG3／CRYPT | `0x00`／`0x0000` |

R19の最初の30秒候補でも、E220の永続レジスタ、UART rate、air rate、sub-packet sizeは変更しない。電源不足による低電力モードは主因として立証されていないため、現在は変更仮説から外す。

## 5. R18標準TDDの基準仕様

| 項目 | 値・規則 |
|---|---|
| 1周期 | 5,000 ms |
| Vehicle downlink区間 | 3,000 ms |
| Vehicle receive区間 | 2,000 ms |
| Ground uplink前guard | 650 ms |
| Ground新規transaction開始窓 | 300 ms |
| return guard | 650 ms |
| 制御frame | canonical v2、exact 32 bytes、CRC-16/CCITT-FALSE |
| 物理write | 最大32 bytes、all-or-nothing |
| production service floor | full write後550 msかつAUX HIGH連続15 ms |
| started transaction deadline | 最初のDATA Acceptedから2,000 ms |
| 上り | 1 Grantにつき最大1 complete MAVLink frame |

制御frameをPixhawk UARTまたはMission Planner USBへ漏らさない。CRC-validな完全MAVLink frameだけを転送し、active frameを分割順序の途中で入れ替えない。

## 6. 受入基準

### 6.1 R18低速信頼性基準

- `PARAM_VALUE`をexact `932/932`件取得する。
- indexは`0..931`、欠落、重複、順序異常、範囲外、`param_count`不一致をすべて0とする。
- Mission Planner受入区間のprimary Heartbeat最大間隔を`2,500 ms`以下とする。
- MAVLink CRC、partial frame、noise、control leakage、parser anomalyを0とする。

### 6.2 R19高速受入基準

R19では上記の完全性を緩和せず、次を追加する。

| 項目 | 定義・合格値 |
|---|---|
| `t0` | Ground USBで完全な`PARAM_REQUEST_LIST`（msgid 21）を受理した時刻 |
| `t1` | Ground USBホストが最終`PARAM_VALUE`（msgid 22、index 931）を物理的に取得完了した時刻 |
| 完了時間 | `t1 - t0 <= 30,000 ms` |
| Heartbeat | first／max／post gapすべて`<=2,500 ms` |
| parameter | exact 932件、strict index order、欠落・重複0 |
| retry | 拒否されたwriteは同一bytesを保持し、件数・ordinalを進めない |
| terminal evidence | VCTAは`t1`後に送信し、30秒SLAへ混ぜない |

`t1`はXIAO内部FIFOへの格納時刻ではなく、Ground USBのloss epochが変化せず、最終endpoint packetがホストへpickupされた結果を持つcommit時刻である。

## 7. 実機で確認済みのR18結果

正本: [`runs/hil/POST-R18-MISSION-PLANNER-PRODUCTION-001/20260917T095932Z/report.md`](runs/hil/POST-R18-MISSION-PLANNER-PRODUCTION-001/20260917T095932Z/report.md)

| 測定項目 | 結果 |
|---|---:|
| 実機判定 | PASS（low-speed production path） |
| Indexed parameters | 932 / 932 |
| Missing／duplicate／out of order | 0 / 0 / 0 |
| Request → first parameter | 298.124 s |
| First → last parameter | 5,747.715 s |
| Request → completion | 6,045.839 s（100.764 min） |
| Primary Heartbeat count | 5,734 |
| Heartbeat最大間隔 | 2,206.203 ms |
| Heartbeat余裕 | 293.797 ms |
| Heartbeat超過 | 0 |
| relevant CRC／parser anomaly | 0 / 0 |

この結果はMission Planner、MAVLink、Pixhawk、Ground／Vehicle XIAO、E220を含む完全往復経路が成立する証拠である。R19高速経路の証明ではない。

## 8. R19高速転送仕様

### 8.1 wire record

| record | 用途 | wire条件 |
|---|---|---|
| Standard Grant | Groundが上りを開始できる周期・sessionの証明 | exact 32 bytes |
| `VCBN` | 高速転送の要求／応答、identity・nonce・challenge・lease合意 | exact 32 bytes／record |
| `VCB1` | PARAM_VALUEと実Heartbeatのbulk downlink | exact 32 bytes／fragment、payload 19 bytes |
| `VCTA` | Ground実績をVehicleへ返すterminal evidence | 8 × 32 bytes、canonical record 144 bytes |
| `VCRC` | 相手側が指定recordを完全受理したことを返す相関receipt | exact 32 bytes／record |

各`PARAM_VALUE`は37 bytesなので、VCB1ではHEAD＋TAILの2 fragmentになる。unsigned MAVLink2 Heartbeatも21 bytesなので同じく2 fragmentになる。VCB1はtransfer tag、transfer-global ordinal、kind、payload length、CRCを保持する。

### 8.2 exact会計

| 項目 | 値 |
|---|---:|
| PARAM_VALUE | 932 frame |
| raw MAVLink parameter bytes | 34,484 bytes |
| parameter VCB1 fragments | 1,864 chunk |
| parameter padded RF bytes | 59,648 bytes |
| conservative Heartbeat | 31 frame／62 chunk |
| Grant | 1 chunk |
| VCBN request＋response | 2 chunk |
| negotiation VCRC | 1 chunk |
| `t0..t1` critical total | 1,930 chunk／61,760 bytes |
| post-SLA VCTA | 8 chunk／256 bytes |
| post-SLA terminal VCRC | 1 chunk／32 bytes |
| full session total | 1,939 chunk／62,048 bytes |

### 8.3 30秒計算

現行profileのpayload-only下限は次である。

```text
61,760 bytes × 8 / 19,200 bps = 25,733.333... ms → 25,734 ms
```

| ケース | 下限計算 | 判定 |
|---|---:|---|
| 現在の4.6 s Grant待ち | 25,734 + 4,600 + 400 guard + 100 USB = 30,834 ms | 30秒不可能 |
| 500 ms Grant候補 | 25,734 + 500 + 400 guard + 100 USB = 26,734 ms | 算術上可能、未実証余裕3,266 ms |
| full session（VCTA＋terminal VCRCを含む） | 25,854 + 500 + 600 guard + 100 USB = 27,054 ms | 算術下限のみ |
| 10秒目標 | RF payload下限だけで25,734 ms | 現行profileでは不可能 |

オフラインtransport modelは、nominal pipelined `27,171 ms`、non-overlap `29,469 ms`を出している。ただしLoRa packet overhead、AUX／remote drainの不確実性、retry、USB／OS jitterを物理上限として証明した値ではない。したがって`physical_30s_proven=false`、`live_flash_authorized=false`を維持する。

## 9. R19で実装・修正済みの範囲

- VCBN codec、demux、session identity、nonce／challenge照合
- VCB1 codec、demux、receiver rearm、strict transfer tag
- fixed-storage `BulkDataTxLease`
- PARAM_VALUE／Heartbeatの完全frame transcriptとdigest入力
- bulk Heartbeat保持、deadline、first／max／post SLA ledger
- Ground USB host-visible最終commit ownerとloss-epoch照合
- VCTA wire codec、producer、bridge、reassembler
- Ground／Vehicle bulk session controller
- high-speed TDD coordinator
- platform-neutral Phase 6 high-speed adapter seam
- accepted R18 product bridgeへのdefault-off feature-gate統合
- passive standard Grant引継ぎと4回の100 ms方向guard
- 送信拒否時に同一lease／同一fragmentを保持するretry修正
- accepted時だけwire ordinalと件数を進める会計
- ordinal入替・反復、HEAD/TAIL不一致、偽の早期完了をfail-closed
- VCBNを意味検証してからremote-tailとして採用するprevalidation順序
- VCTA全8 fragmentのreassembly／exact identity確認後だけstreamを閉じる規則
- exact 32-byte VCRC codec、producer、ledger、demuxとdirection相関
- peer completion receiptの絶対deadline `1,300 ms`（境界は受理、`1,301 ms`はfail-closed）
- continuous AUX HIGH時のbounded 400-byte local credit回復。これは最終RF tail／方向変更の証明には使用しない
- accelerated sessionは1 bootにつき1回。2回目以降はstale evidenceを再利用せずR18低速経路へ安全にfallback
- 診断macro限定の固定112-byte／28-word Endpoint FIFO record（schema 2）。先頭24 wordはschema 1のoffsetを維持し、末尾4 wordへflush outcome／task-ZLP／ISR-ZLP／terminal blockerをappendする。既存68-byte runtime-stage ABIは変更しない
- record-owned flagsはbit 11 `PayloadPublishPending`、bit 12 `PayloadPublishAborted`、bit 13 `PayloadFlushPending`、known maskは`0x00003FFF`。positive FIFO writeでpublish／flush pendingをarmし、matching non-ZLP `WR_DONE`でpublish pendingだけをclear、同じ新規publicationのclean flush successだけがflush pendingをclearする。BUS_RESET又はtask discardはpendingをclearしてaborted barrierをsetし、次のpositive publicationだけがbarrierをclearする
- zero-byte writeはpayloadをretry用に保持し、publication／`WR_DONE`／flush／quarantine証拠を作らない。`IN_EMPTY` pickup直前にBUS_RESETをTX mux内で再sampleし、late resetはraw-only reset-discard会計へ送る
- JTAG reader-v3はhalt中に68-byte runtime-stageと112-byte Endpoint FIFO recordを各2回取得し、symbol、size、安定性、generation、known mask、counter／accounting、address非重複に加え、last-event BUS_RESET、publish pending／aborted、flush pending、decoded flag coherenceをfail-closed検証する

関連実装:

- [`core/include/vc_lora/bulk_session_controller.hpp`](core/include/vc_lora/bulk_session_controller.hpp)
- [`core/include/vc_lora/high_speed_tdd_coordinator.hpp`](core/include/vc_lora/high_speed_tdd_coordinator.hpp)
- [`core/src/high_speed_tdd_coordinator.cpp`](core/src/high_speed_tdd_coordinator.cpp)
- [`firmware/high_speed/high_speed_phase6_adapter.hpp`](firmware/high_speed/high_speed_phase6_adapter.hpp)
- [`firmware/high_speed/e220_high_speed_transport_model.hpp`](firmware/high_speed/e220_high_speed_transport_model.hpp)
- [`firmware/high_speed/peer_completion_receipt.hpp`](firmware/high_speed/peer_completion_receipt.hpp)
- [`firmware/phase6/vc_lora_phase6_bridge.hpp`](firmware/phase6/vc_lora_phase6_bridge.hpp)
- [`firmware/high_speed/terminal_ack_wire.hpp`](firmware/high_speed/terminal_ack_wire.hpp)
- [`firmware/high_speed/terminal_ack_producer.hpp`](firmware/high_speed/terminal_ack_producer.hpp)
- [`firmware/high_speed/terminal_ack_bridge.hpp`](firmware/high_speed/terminal_ack_bridge.hpp)
- [`third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h`](third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h)
- [`tools/read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1)

## 10. 検証状況

| 検証 | 結果 | 範囲・注意 |
|---|---|---|
| R18 Mission Planner HIL | PASS | 932/932、HB max 2,206.203 ms |
| R19 product route source契約 | PASS | required 25／present 25／missing 0 |
| focused product regression | 17/17 PASS | VCRC、deadline、prevalidation、coordinator、demux、accounting、E2E |
| fresh全ホストsuite | 305/305 PASS | 完全版Clang 22.1.8、CTest FAIL 0。internal 275 PASS＋expected XFAIL 2＋FAIL 0。不完全fallbackの`<regex>`欠落は環境停止として分離 |
| fresh Clang ASan／UBSan全suite | 303/303 PASS | Section 31.17修正後、skipped 0、ASan 0、UBSan 0 |
| R19 real-type route E2E | PASS | host model上で932 parameterとterminal evidenceを確認 |
| Section 26旧診断candidate Vehicle compile | PASS | flash 431,101 bytes／RAM 106,232 bytes |
| Section 26旧診断candidate Ground compile | PASS | flash 402,757 bytes／RAM 69,832 bytes |
| normal/default-off Vehicle compile | PASS | flash 390,613 bytes／RAM 101,920 bytes、新HWCDC coreで再compile |
| normal/default-off Ground compile | PASS | flash 360,849 bytes／RAM 65,512 bytes、新HWCDC coreで再compile |
| sketch同期／Phase 6 firmware契約 | PASS | candidate packagingは既定無効 |
| 旧R19診断flash／dual-COM HIL | 2回FAIL | 両回0 byte、各回accepted R18へrollback PASS |
| Section 26 bootstrap診断candidate HIL | **3回目FAIL** | 両COM 0 byte、install／R18 rollback PASS、許可消費済み |
| Section 28 false-SOF／ZLP修正 | offline PASS | normal/sanitizer 301/301、semantic 33/33、installer／compile／seal／verifier PASS |
| Section 28 fresh診断candidate HIL | **4回目FAIL** | 両COM 0 byte、install／R18 rollback PASS、許可消費済み |
| Section 30 runtime-stage診断candidate HIL | **FAIL** | 両COM 0 byte、JTAGはUSB open前に失敗、accepted R18 rollback PASS |
| Section 31 JTAG pre-flash gate | **FAIL_CLOSED** | 両MI_02のWinUSB user-mode interface未登録。R19書込み・COM open・halt/resetなし |
| Section 31.16 runtime-stage HIL | **通信FAIL／原因境界取得PASS** | 両COM 0 byte、両role `WriteAccepted`後`FlushFailed`、JTAG cleanup証明、accepted R18 rollback PASS |
| Section 31.17 direct-payload prime | **offline PASS／実機未確認** | HWCDC 35/35、normal・ASan/UBSan 303/303、candidate `20261010T090523384Z-93c6076d`をVehicle→Ground compile・seal・verify |
| Section 31.18 competing-client ancestry修正 | **offline PASS／実機未確認** | 書込み前の自己競合誤検出を限定修正、全host 303/303、Vehicle→Ground compile PASS |
| Section 31.20 Endpoint FIFO／flush境界診断 | **historical schema1 offline PASS** | model 67/67、source 32/32、semantic 42/42、reader 82/82、全host 304/304、Vehicle→Ground compile・seal・verify PASS |
| Section 31.21 Endpoint FIFO実機診断 | **診断PASS／通信FAIL** | FIFO write／WR_DONE／IN_EMPTY／payload pickup成立、両COM 0 byte、accepted R18 rollback PASS |
| Section 31.22 final-ZLP再発行抑止 | **offline PASS／後続実機で十分性なし** | 決定論モデル44/44、HWCDC／installer契約PASS。Section 31.23で単独では継続通信を回復しないことを確認 |
| Section 31.23 final-ZLP修正後実機診断 | **診断取得PASS／通信FAIL** | COM3 0 byte、COM6 HEARTBEAT 1件、診断beacon 0、Vehicle flush 0/5、Ground clean-boundary収束失敗、accepted R18 rollback PASS |
| Section 31.24 schema2 diagnostic trust closure | **offline PASS／実機未確認** | record 153/153、LL 59/59、product-source 45/45、runtime 203/203、semantic 61/61、reader 113/113、outer／installer／builder／pin cascade PASS。fresh候補をVehicle→Ground compile・seal・独立verify |
| Section 31.30 short-packet／task-prime原因分離HIL | **診断取得PASS／通信FAIL** | 両COM 0 byte。Vehicleは31-byte short packet後の不要ZLP待ち、Groundは後続21 byteのclean-idle再prime欠落。accepted R18 rollback PASS |
| Section 31.31 short-packet／task-prime修正 | **offline PASS／実機未確認** | focused 4/4、reader 115/115、全host 305/305、通常compile及び診断候補build・seal・verify PASS |
| R19 Mission Planner 30秒HIL | 未合格 | 30秒／HB物理証明はPARTIAL |

主要証拠:

- [`runs/high_speed/HS-CANDIDATE-OFFLINE-001/summary.json`](runs/high_speed/HS-CANDIDATE-OFFLINE-001/summary.json)
- [`runs/high_speed/HS-TERMINAL-ACK-CODEC-001/LATEST/summary.json`](runs/high_speed/HS-TERMINAL-ACK-CODEC-001/LATEST/summary.json)
- [`runs/validation/R19-HS-TERMINAL-TIMEOUT-001/summary.json`](runs/validation/R19-HS-TERMINAL-TIMEOUT-001/summary.json)
- [`runs/UT-HS-TDD-COORD-005/summary.json`](runs/UT-HS-TDD-COORD-005/summary.json)
- [`runs/UT-HS-PHASE6-ADAPTER-006/summary.json`](runs/UT-HS-PHASE6-ADAPTER-006/summary.json)
- [`runs/validation/R19-P0-PRODUCT-ROUTE-001/GREEN/implementation_summary.md`](runs/validation/R19-P0-PRODUCT-ROUTE-001/GREEN/implementation_summary.md)
- [`runs/host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)
- [`runs/validation/R19-HWCDC-DIRECT-PAYLOAD-PRIME-OFFLINE-001/20261010T-red/summary.json`](runs/validation/R19-HWCDC-DIRECT-PAYLOAD-PRIME-OFFLINE-001/20261010T-red/summary.json)
- [`fresh diagnostic candidate manifest`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261010T090523384Z-93c6076d/candidate_manifest.json)
- [`current FIFO diagnostic candidate manifest`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T130746575Z-da934683/candidate_manifest.json)
- [`Section 31.20 offline evidence`](runs/contracts/FW-R19-HWCDC-FIFO-DIAGNOSTIC-001/20261011T132801179Z/summary.json)
- [`Section 31.21 live FIFO evidence`](runs/validation/R19-HWCDC-FIFO-LIVE-DIAG-001/20261011T134548155Z/summary.json)
- [`Section 31.22 product candidate manifest`](runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/20261011T140505553Z-18941c96/candidate_manifest.json)
- [`Section 31.22 diagnostic candidate manifest`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T141348202Z-34b9e8b0/candidate_manifest.json)
- [`Section 31.23 live evidence`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T143454467Z-8fd2c3b7/summary.json)
- [`Section 31.23 offline review`](runs/validation/R19-HWCDC-FINAL-ZLP-LIVE-DIAG-001/20261012T-offline-summary/summary.json)
- [`Section 31.24 HWCDC schema2 evidence`](runs/validation/R19-HWCDC-PUBLISH-PENDING-OFFLINE-001/20261012T045500000+0900/summary.json)
- [`Section 31.24 pin cascade evidence`](runs/validation/R19-PIN-CASCADE-CLOSURE-OFFLINE-001/20261012T060139721+0900/summary.json)
- [`Section 31.24 fresh diagnostic candidate`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T213059634Z-4a5ff626/candidate_manifest.json)
- [`Section 31.24 integrated offline evidence`](runs/validation/R19-HWCDC-DIAGNOSTIC-TRUST-CLOSURE-OFFLINE-001/20261012T065057148+0900/summary.json)

## 11. 未解決課題

### P0: オフライン製品統合

完了。通常Grant引継ぎ、100 ms方向guard、VCB1／VCTA相関、VCRC、writer排他、default-off feature gateを製品経路へ統合し、test-first回帰とsanitizerを通過した。

### P1: 残るソフトウェア制約

- accelerated sessionは1 bootにつき1回である。同一bootの2回目はR18低速経路へ安全にfallbackする。複数回の高速取得を要求する場合は、one-shot evidence ownerの安全な再armを別変更として実装する。
- 追加測定器なしでは、AUX、airtime、remote RF tailを独立計測する直接証拠は得られない。この部分はPARTIALのまま、相手側VCRCとE2E結果で判定する。
- E220印字型式の最終BOM確認は未完了である。現行profileは書き換えない。
- 現行claimはtrusted local repo／toolchainを前提とする。生成semantic summaryはsealへbindされるが、敵対的なrepo／toolchain又はTOCTOUに対するchecker executable自身の独立provenance封印は未完了であり、追加hardening項目とする。

### P2: 実機受入

- JTAG driver/interface、active pre-flash gate、各CPUのhalt／resume／shutdown証明はSection 31.16の実機試験で解消・確認済みである。
- Section 31.16では両roleともCDC 0 byteだったが、68-byte runtime stageからsetup、loop、host gate、frame stage、write attempt、`WriteAccepted`まで到達し、その後`FlushFailed`となる共通境界を確定した。
- Section 31.17のdirect-payload primeは、この実測と整合するsoftware liveness gapを閉じるoffline候補である。実機未確認のため、0 byteの根本原因確定又は修復完了とは判定しない。
- Section 31.18の直近HILはinstall前に停止し、candidateもR18も書き込まれていない。`rollback.proven=false`は復旧書込み失敗ではなく、rollback-onlyもdevice接続前に同じ競合gateで停止したことを意味する。本run単独では実機R18のreadbackは行っていない。
- Section 31.24のschema2 112-byte FIFO recordとreader-v3はoffline検証済みである。Section 31.21／31.23のlive evidenceはschema1 96-byte recordによる履歴であり、bit 11–13の実機値はまだ取得していない。FIFO書込みとpayload pickupは履歴runで証明したが、R19の継続CDC通信は未解消である。
- Section 31.21で96-byte recordの実機取得は成立し、device-side FIFO writeとpayload pickupまでは確認した。ただしWindows側受信は両COM 0 byteのため、USB host-visible deliveryは未解決である。Vehicleでflush successが1回あってもuser-space受信0 byteであり、現行flush successをhost-visible commit証拠として扱わない。
- Section 31.22の最終ZLP再発行抑止はSection 31.23で実機評価済みである。COM6へ通常HEARTBEAT 1件は到達したが、診断beaconは0件、Vehicle flushは5/5 timeoutだったため、この修正だけでは継続通信を回復できない。
- `GroundBoundaryImpossible`は複数の失敗分岐を一つに集約しており、detail `5884`はmonotonic時刻であって分岐codeではない。現行証拠だけではhost loss、epoch／deadline、backlog discard、invalid pump、boundary flush失敗／遅延のどれかを一意に決められない。
- 直近のaccepted R18再証明HILはVehicle full-length read-flashを完了できずfail-safe停止した。Vehicleはexact USB role再列挙済みだがaccepted R18未証明、Groundは未操作かつ本run内未証明である。erase／firmware writeは0、一回限定許可は消費済み、`power_off_required=false`、`live_flash_authorized=false`である。
- schema2 offline closure、canonical core install、Vehicle→Groundの通常版／診断版compile、fresh候補seal／独立verifyは完了しているが、両roleのaccepted R18状態を別の実機証拠で再確定するまでR19候補の実機診断へ進まない。旧schema1候補`20261011T141348202Z-34b9e8b0`は履歴専用で、現行gateでは再書込み対象外である。
- 有効なR19A/R19F取得までがbootstrap診断受入であり、932件30秒受入とは別である。
- 診断HILが成立した後だけ、別許可・別試験で`t0`、全932件、`t1`、Heartbeat、CRC／parser／tail／retry／VCRCを同時取得する。
- `932/932`、`t1-t0 <= 30,000 ms`、Heartbeat max `<=2,500 ms`、全error 0を同時に満たした場合だけ30秒達成と判定する。

## 12. 変更・試験時の不変ルール

- 変更前に失敗するテストを追加し、RED→GREENの証拠を残す。
- 一つの変更でTDDロジックと通信パラメータを同時に変更しない。
- canonical coreへArduino、`HardwareSerial`、dynamic allocationを持ち込まない。
- Mission Planner用USBへdebug文字列や独自binary診断を流さない。
- accepted byteだけをFIFOから消費し、Rejected／zero writeで状態を進めない。
- 制御frameをPixhawk／GCSへ漏らさない。
- 欠落、重複、順序、Heartbeat基準を緩和して合格させない。
- core変更後はVehicle→Groundの順にArduino compileする。
- 実機書込み前に、対象binary、role、COM、電源状態、source hashを確認する。
- R19の`live_flash_authorized`がfalseの間は、候補コードを実機へ書き込まない。

## 13. 再開手順

```text
1. Section 31.23 historical live evidenceとSection 31.24 schema2 offline evidenceを区別して照合する
2. 実機状態をaccepted R18（Vehicle SHA `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground SHA `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`）、`live_flash_authorized=false`として確認する
3. schema2 112-byte／reader-v3を含むfresh diagnostic candidate `20261011T213059634Z-4a5ff626`のmanifest／handoff／seal／app hashesを確認する。schema1候補`20261011T141348202Z-34b9e8b0`を再使用しない
4. 新しい一回限定許可と安全条件6項目確認を得る
5. accepted R18のままstandalone active-JTAG pre-flash gateをVehicle→Ground順に実行する
6. gate PASS後だけfresh schema2 candidateをapplication-only flashする
7. COM3 115200 bps／COM6 57600 bpsを40秒read-only同時取得する
8. 各roleから68-byte runtime-stage＋112-byte schema2 FIFO recordを各2回reader-v3で読み、BUS_RESET／publish／flush barrierと全会計を判定する
9. 成否に関係なくaccepted R18へrollbackし、readback digest／re-enumeration／CPU running／shutdownを証明する
10. bootstrapが成立した後だけ、別許可で932/932・30,000 ms・Heartbeat 2,500 ms・全error 0を同時評価する
```

途中で一つでも完全性、物理tail、方向guard、型式・電源条件に未確定があれば、R18低速productionを維持し、R19をdeploymentしない。

## 14. 関連正本

| 文書 | 主な内容 |
|---|---|
| [`README.md`](README.md) | 接続、設定、使用ファイル、運用手順 |
| [`SPEC.md`](SPEC.md) | 基本ハードウェア、固定通信値、合格条件 |
| [`PROTOCOL.md`](PROTOCOL.md) | 標準TDD、制御wire、状態遷移 |
| [`TEST_PLAN.md`](TEST_PLAN.md) | ホスト、Arduino、HIL試験計画 |
| [`HIL_TEST_PLAN.md`](HIL_TEST_PLAN.md) | 実機構成、電源操作、証拠取得 |
| [`HOST_TEST_SPEC.md`](HOST_TEST_SPEC.md) | ホスト試験仕様と不変条件 |
| [`firmware/phase6/README.md`](firmware/phase6/README.md) | R17/R18 Heartbeat／USB commit契約 |
| [`firmware/high_speed/vc_lora_high_speed_candidate.hpp`](firmware/high_speed/vc_lora_high_speed_candidate.hpp) | R19の計算可能な候補定数とclosed live gate |
| [`third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h`](third_party/esp32-core-3.3.11-vc-lora/cores/esp32/HWCDCR19Diagnostic.h) | 診断macro限定のschema2 112-byte／28-word Endpoint FIFO JTAG record ABI |
| [`tools/read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1) | reader-v3。68-byte runtime-stage＋112-byte schema2 FIFO recordの安定JTAG読取り・fail-closed分類 |
| [`Section 31.20 offline evidence`](runs/contracts/FW-R19-HWCDC-FIFO-DIAGNOSTIC-001/20261011T132801179Z/summary.json) | historical schema1 implementation evidence |
| [`Section 31.24 schema2 implementation evidence`](runs/validation/R19-HWCDC-PUBLISH-PENDING-OFFLINE-001/20261012T045500000+0900/summary.json) | reset race、bit 11–13、reader／outer fail-closedの正本 |
| [`Section 31.24 fresh candidate`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T213059634Z-4a5ff626/candidate_manifest.json) | schema2診断候補のcompile、ABI、app hashes、toolchain入力 |
| [`Section 31.24 final seal`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T213059634Z-4a5ff626/final_seal.json) | manifest／handoff／semantic証拠の封印 |

## 15. Jev診断ゲート Phase A（2026-09-23）

[`Jev_Integration_and_Token_Measurement_Spec_R19.md`](Jev_Integration_and_Token_Measurement_Spec_R19.md)
を設計入力として、PC側のshadow評価のみ実装した。実装入口は
[`tools/jev_advisor/README.md`](tools/jev_advisor/README.md)である。

- 固定判定はJevより先に実行し、`932/932`、30,000 ms、Heartbeat 2,500 ms、
  全error 0を緩和しない。
- 入力例だけでは不足していた完了時間、Heartbeat件数とfirst/max/post gap、欠落・重複・順序、
  partial/control leakage、retry identity、Grant/guard、VCB1/VCTA tail状態を必須化した。
- `source_manifest`の正規化hashと実ファイルbytesを照合し、host model証拠とHIL physical証拠を分離した。
  host成功は`PASS_HOST_MODEL`であり、実機受入`PASS_FIXED`とは扱わない。
- 失敗件数だけから原因を推測しないよう、`failed_test_ids`を必須化し、件数一致を検証する。
- Jevは曖昧な場合だけ、閉じた8 actionから1件を選ぶ。Phase Aではactionを実行しない。
- API無効・失敗・不正応答・低confidenceは`COLLECT_MORE_EVIDENCE`へfail-closeする。
- `CODE_REVIEW_REQUIRED`だけが、最大12ファイルの明示allowlistからrunへ結合したhash付き限定contextを生成できる。
- Token計測v2ではOpenAI raw usageを正規化し、保存後の`input_tokens`は非cache、
  `total_tokens = input_tokens + cached_input_tokens + output_tokens`とする。
  provider receipt、rate-card出典、人手判定の根拠が揃うまで削減効果は主張しない。
- Node/npmが存在しないため、仕様書の`.ts`例は既存Python 3.12標準ライブラリ実装へ写像した。

2026-09-24時点で、Jev関連unit 35/35とschema/policy契約がPASSしている。
合成host-model入力を用い、`typesafe-ai/jev`、TypeSafe provider固定、
request option `zeroDataRetention=true`で1回のlive shadow smokeが成功した。記録値は
input 1,064／output 125 tokens、generation
`gen_01M393QWD3MRMHV834WTDABF5Q`であり、actionは提案のみで実行していない。
これはAPI経路の疎通確認であり、R19実機受入証拠ではない。成果物は
[`runs/validation/R19-JEV-LIVE-SMOKE-001/R19-JEV-DRY/summary.json`](runs/validation/R19-JEV-LIVE-SMOKE-001/R19-JEV-DRY/summary.json)
へbyte同一で封印した。

実保存summary 4件はbyte単位のmanifest照合を行い、
[`runs/validation/R19-JEV-REAL-INPUT-001/input.json`](runs/validation/R19-JEV-REAL-INPUT-001/input.json)
へ集約した。offline Shadow結果は
[`runs/decision/R19-REAL-OFFLINE-001/summary.json`](runs/decision/R19-REAL-OFFLINE-001/summary.json)
である。対象replayは`OFFLINE_SELF_TEST`のhost modelであり、完全なphysical HIL証拠ではない。
932/932、23,575 ms、Heartbeat最大1,000 msを記録したが、物理証拠状態が未確定で
host suiteにも1件のFAILがあるため、固定判定は`EVIDENCE_REQUIRED`、
actionは`RUN_FOCUSED_GRANT_TEST`、`jev_called=false`となった。

この時点の実装、4原資料、offline Shadow、全58 Python試験、Jev関連35試験、
schema/policy契約および構文検証は、
[`runs/validation/R19-JEV-PHASE-A-V3-001/summary.json`](runs/validation/R19-JEV-PHASE-A-V3-001/summary.json)
を入口として封印した。ソフトウェア検証はPASSだが、工学判定は
`EVIDENCE_REQUIRED`であり、両者を同一視しない。

`RUN_FOCUSED_GRANT_TEST`は2026-09-24にPC上で実行した。現行sourceからhost binaryを
再構築し、`UT-HS-TDD-COORD-001..005`と`UT-HS-PHASE6-ADAPTER-002`は6/6 PASSした。
結果は
[`runs/validation/R19-JEV-FOCUSED-GRANT-HOST-001/20260924T075138932Z/summary.json`](runs/validation/R19-JEV-FOCUSED-GRANT-HOST-001/20260924T075138932Z/summary.json)
へ保存した。これによりbyte-identical retry identityとGrant handoff境界はhost-model範囲で
確認できたが、accepted R18 production pathへの接続、実RF tail、物理handoffは未証明である。
COM、実機、ネットワーク、firmware、E220、通信設定には触れていない。

同試験後のArduino compileは契約preflightで安全停止した。host coreの
`tdd_link_demux.cpp`にはR19 VCBN認識がある一方、Vehicle/Ground production copyは
accepted R18のままであり、無断同期を禁止する契約が差異を検出したためである。詳細は
[`runs/validation/R19-JEV-FOCUSED-GRANT-ARDUINO-PREFLIGHT-001/20260924T075825139Z/summary.json`](runs/validation/R19-JEV-FOCUSED-GRANT-ARDUINO-PREFLIGHT-001/20260924T075825139Z/summary.json)
に保存した。両sketchのcompile、COM接続、書込みは行われていない。R19 coreをproductionへ
取り込む場合は、accepted R18を維持したまま別のtest-first integrationとして扱う。

Codex単独とJev併用の比較は、対になる正確なprovider usage receipt、
出典付きrate card、人手判定根拠が未完了である。したがってtoken・cost・処置妥当性の
改善効果はまだ主張しない。機器書込み、COM接続、E220変更、Mission Planner HILは
今回実施しておらず、`live_flash_authorized=false`を維持する。

## 16. R19 source-copy repair（2026-09-24）

R19 canonical coreをVehicle、Ground、およびstable診断版2系統のsketch-local copyへ同期した。
各roleはcanonicalと同一の20 cpp／26 hppとなり、missing、extra、hash mismatchはいずれも0である。
Phase 6契約文書は内容を変更せず、仕様索引とsource契約が要求する
[`firmware/phase6/README.md`](firmware/phase6/README.md)へ正規化した。

PC上で次を確認した。

- `FW-ARDUINO-CONTRACT-001`: PASS
- host CTest: 250/250 PASS
- aggregate: 249 PASS、既定XFAIL 2、FAIL 0
- Vehicle clean compile: PASS、binary SHA-256
  `C9B917629DB885AC9F93B1E7C3015CEE3EB79894E1179D06E6A2CD3698A7B0DC`
- Ground clean compile: PASS、binary SHA-256
  `FE8F7197592C252C67B6A4C035F146B66E3B601B3595F922EF9B00491482B7DB`
- firmware manifest: verified、SHA-256
  `EEAFDB186792E513CFA558BEB4280A6569BDFFF62BAB5126E95E6497F1C11EF6`

証拠は
[`runs/validation/R19-PRODUCTION-CORE-SYNC-001/20260924T081618666Z/summary.json`](runs/validation/R19-PRODUCTION-CORE-SYNC-001/20260924T081618666Z/summary.json)
に保存した。COM接続およびfirmware書込みは実施していない。この修正はR19候補のsource copyを
契約整合・compile可能にしたものであり、高速product routeを有効化する変更ではない。
この時点ではP0の5項目が未解決だったが、後続のSection 17で製品統合まで完了した。封印済みR18 rollback artifactは未変更である。

## 17. R19 P0 product-route統合（2026-09-24、現行）

Section 16後に、通常Grant引継ぎ、VCBN prevalidation、4方向guard、VCB1／VCTA exact相関、VCRC receipt、continuous AUX HIGH時のbounded local credit、およびproduction writer排他をtest-firstで統合した。候補は`VC_LORA_R19_HIGH_SPEED_CANDIDATE=1`の場合だけ選択され、既定値は`0`である。

現行の最終オフライン結果は次のとおりである。

- product source contract: 25/25 PASS
- 全host CTest: 276/276 PASS、FAIL 0
- fresh Clang ASan／UBSan: 276/276 PASS、sanitizer report 0
- candidate Vehicle／Ground compile: PASS
- normal/default-off Vehicle／Ground compile: PASS
- canonical core／sketch-local copy同期とPhase 6契約: PASS
- COM3／COM6のopen、flash、reset、実機操作: 未実施

詳細は
[`runs/validation/R19-P0-PRODUCT-ROUTE-001/GREEN/implementation_summary.md`](runs/validation/R19-P0-PRODUCT-ROUTE-001/GREEN/implementation_summary.md)
と
[`runs/host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)
を正本証拠とする。物理30秒およびHeartbeat同時合格はまだ実証していないため、`physical_30s_proven=false`、`live_flash_authorized=false`を維持する。

## 18. R19実機受入preflight（2026-09-25、現行）

Section 17のsourceから、R19候補を明示的に有効化したVehicle／Groundのapplication-only
artifactを生成し、書込みと測定を別々のsealed evidenceで拘束するpreflightを追加した。
通常製品版の既定値`VC_LORA_R19_HIGH_SPEED_CANDIDATE=0`は変更していない。

公開済み候補は次の一世代である。ディレクトリの日時順ではなく、固定SHA付きの
[`latest.json`](runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/latest.json)
から選択する。

- artifact ID: `20260924T225602548Z-0e5fbd9d`
- `latest.json` SHA-256:
  `EA42FE7E778B9453D724821A3EB9C900329079D1A88063EA1A1715992F3C5D7A`
- candidate manifest SHA-256:
  `11A25A84CBC19205B59C633A4EB8567FE38C30561D0A7F03B81132A15CF3A289`
- handoff SHA-256:
  `A6F852AC5616220EBD6229472394D12E51A8936CE0A5CE6C955412384428221A`
- final seal SHA-256:
  `0FB0F9FC6544481B867310F6A5E1E691CAC922D6BE1E81B2C990E5B47AF0513B`
- Vehicle application: 424,048 byte,
  `68133AC035E5EA056AC9CA0F846DD0DC08A8DC0BDDB915CBFB1C81E8AB48D967`
- Ground application: 394,864 byte,
  `9C64D38E1A5B3A355B61C9030E909BDD37D79223B68BDCC7661B57F49516DE12`
- artifact内の`.bin`は上記application 2本だけで、flash offsetは`0x10000`

候補生成時にArduino CLIがsketch配下へbootloader、partition、merged image等を暗黙出力する
挙動を検出した最初の世代は、安全側で失敗として隔離した。`latest.json`へは公開しておらず、
実機にも書き込んでいない。修正版は生成物を候補packageから除外し、余分な`.bin`を
verifierが拒否する契約試験を含む。

実機preflight用に次を追加した。

- [`tools/build_r19_candidate_artifacts.ps1`](tools/build_r19_candidate_artifacts.ps1):
  候補application、manifest、handoff、inventory、sealを非破壊生成
- [`tools/verify_r19_candidate_artifact.ps1`](tools/verify_r19_candidate_artifact.ps1):
  artifact root／manifest／handoff／固定latestの4経路検証と改ざん拒否
- [`tools/invoke_r19_candidate_app_flash_hil.ps1`](tools/invoke_r19_candidate_app_flash_hil.ps1):
  COM3 Vehicle→COM6 Ground、application-only `0x10000`、read-back、再列挙、失敗時R18復元
- [`tools/run_r19_pixhawk_param_list_e2e_hil.ps1`](tools/run_r19_pixhawk_param_list_e2e_hil.ps1):
  COM6だけを使用する一回限りの厳密受入runner
- [`R19_CANDIDATE_FLASH_HIL_RUNBOOK.md`](R19_CANDIDATE_FLASH_HIL_RUNBOOK.md):
  安全確認、書込み、測定、R18復元手順

書込みorchestratorのDryRunは
[`runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260924T225934689Z-b7555454/flash_record.json`](runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260924T225934689Z-b7555454/flash_record.json)
で`PASS_DRY_RUN_NO_PROCESS_DEVICE_OR_ESPTOOL_ACCESS`となった。device列挙、process inventory、
esptool、firmware writeはいずれも未実行である。

現行のオフライン結果は次のとおりである。

- 全host CTest: 279/279 PASS、FAIL 0
- native aggregate: 274 PASS、既定XFAIL 2、FAIL 0
- R19候補builder契約: PASS（2世代、latest連鎖、通常版不変、改ざん拒否）
- R19 flash orchestrator契約: PASS（成功、途中失敗＋R18復元、復元未証明の安全停止）
- R19 live runner契約: PASS（30,000,000 usは受理、30,000,001 usは拒否）
- R18厳密runner回帰: 20/20 PASS

R18復元に使用する正本は`R18-PRODUCTION-R4-ACCEPTED`であり、Vehicle SHA-256は
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground SHA-256は
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。

残る物理判定は、同一受入区間でのexact 932件、strict index `0..931`、
`t1-t0 <= 30,000,000 us`、Heartbeat full-window最大`<=2,500,000 us`、Ground USBから
観測可能なCRC／parser／partial／control error 0、pump最大100 ms以下、完了後30秒の
重複0である。追加のRF analyzerなしではE220内部で破棄されたbyteや物理RF tailそのものは
直接証明できないため、その範囲は引き続きPARTIALとする。

このpreflight完了時点でもCOM3／COM6のopen、reset、flash、実機測定は未実施である。
候補manifestは`deployment.authorized=false`、`physical_30s_proven=false`であり、
operator安全確認と明示的な一回限りHIL承認を受けるまでは`live_flash_authorized=false`を維持する。

## 19. R19 physical HIL attempt (2026-09-25)

The first live flash invocation stopped before any candidate write because four
live-only `Add-Member -NotePropertyValue` calls had their mandatory value on an
uncontinued following line. The sealed failure record is:

- [`runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103017414Z-a2005a43/flash_record.json`](runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103017414Z-a2005a43/flash_record.json)
- status: `FAIL_STOP_BEFORE_CANDIDATE_WRITE`
- `firmware_write_attempted=false`
- `firmware_may_have_changed=false`
- rollback: `NOT_REQUIRED`

A regression assertion was added first, observed RED, and the four calls were
then repaired. PowerShell parsing, the three R19 offline contracts, candidate
verification, and a new no-hardware DryRun all passed. The new DryRun record
is:

- [`runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103339934Z-bf1aab4a/flash_record.json`](runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103339934Z-bf1aab4a/flash_record.json)
- status: `PASS_DRY_RUN_NO_PROCESS_DEVICE_OR_ESPTOOL_ACCESS`

After exact COM3/COM6 identity and competing-client checks passed, the pinned
candidate was written application-only in Vehicle then Ground order. Both MAC
checks, writes, readbacks, and re-enumeration checks passed:

- [`runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103438401Z-1c8113c2/flash_record.json`](runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103438401Z-1c8113c2/flash_record.json)
- status: `PASS_CANDIDATE_INSTALLED_HIL_ONE_RUN_ONLY`
- final seal SHA-256:
  `00554BA8504A19CEB2D68424594275E6FC2A560202138AA4884F6E6A2BB56047`
- erase, bootloader, partition-table, and merged-image writes: all false

The one-run R19 Pixhawk E2E measurement did not reach the parameter request.
COM6 opened with the exact fixed identity, but received zero bytes during the
approximately 40-second fresh-heartbeat preflight. The runner therefore failed
closed before writing `PARAM_REQUEST_LIST`:

- [`runs/hil/R19-PIXHAWK-PARAM-LIST-E2E-HIL-001/20260925T103612940Z-8cac158e/summary.json`](runs/hil/R19-PIXHAWK-PARAM-LIST-E2E-HIL-001/20260925T103612940Z-8cac158e/summary.json)
- result: `FAIL`
- failure: `Preflight timeout waiting for two fresh primary 1/1 heartbeats and an idle parser.`
- `ground.raw.bin`: 0 bytes
- `request_attempted=0`
- serial writes: 0
- cleanup: `PASS`

Both devices were immediately restored to the pinned accepted R18
applications. Each role passed on its first restore attempt, including MAC,
write, readback, and re-enumeration:

- [`runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103701966Z-9e1bdd68/flash_record.json`](runs/validation/R19-CANDIDATE-APP-FLASH-HIL-001/20260925T103701966Z-9e1bdd68/flash_record.json)
- status: `PASS_R18_ROLLBACK_COMPLETE`
- Vehicle accepted R18 SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18 SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`

An unsealed read-only post-rollback check, using COM6 at 57600 bit/s with
DTR/RTS disabled and zero writes, observed one complete 21-byte MAVLink2
Heartbeat-like frame during the first uninterrupted 12-second interval. A
separate 30-second check was then performed only after COM6 had been closed and
reopened. That second zero-byte result is not an independent R18 baseline:
accepted R18 intentionally latches `runtime_fail_closed` when the USB
`txLossEpoch()` changes, so the intervening close/reopen can itself stop later
output for that boot. It therefore neither proves a common-path fault nor
exonerates R19. The zero-byte R19 result cannot yet be assigned solely to R19
firmware.

Before another candidate flash, perform a full bench power cycle and prove the
accepted R18 baseline in one uninterrupted COM6 capture: at least two fresh
primary system/component 1/1 heartbeats, an idle parser, and a stable ongoing
cadence. Do not close and reopen COM6 to form a second control interval on the
same boot. Only after this fresh-boot control passes may a new one-run R19
flash/HIL evidence set be created. The 932-frame, 30-second, Heartbeat
2,500-ms, and all-error-zero criteria remain unmeasured; R19 deployment remains
`NO-GO`.

After a complete disconnect/reconnect requested from the operator, COM3 and
COM6 re-enumerated with the pinned XIAO identities and no competing serial
client was present. A single uninterrupted, read-only COM6 capture was then
performed for 40.006537 seconds. No transmit fixture was supplied, DTR and RTS
were disabled, and the captured TX length was exactly zero:

- [`runs/hil/R18-READONLY-HEARTBEAT-BASELINE-001/20260925T121214475Z/measurement.json`](runs/hil/R18-READONLY-HEARTBEAT-BASELINE-001/20260925T121214475Z/measurement.json)
- RX: 1,244 bytes; TX: 0 bytes
- valid MAVLink2 frames: 42, all from system/component `1/1`
- primary Heartbeats: 36; first: 1,133.530 ms; maximum consecutive gap:
  2,106.910 ms; final age: 134.030 ms
- CRC errors: 0; unsupported frames: 0; bad payload lengths: 0;
  partial bytes: 0; TDD control leakage: 0
- 266 non-MAVLink bytes are the complete ESP32-S3 cold-boot ROM banner at the
  start of the capture, not an RF parser corruption
- six unsolicited `PARAM_VALUE` frames were present before any host request;
  all used `param_index=65535` and named `BARO1_GND_PRESS`,
  `BARO2_GND_PRESS`, `INS_GYROFFS_X`, `INS_GYROFFS_Y`, `INS_GYROFFS_Z`, and
  `INS_GYR_ID`

This proves that the accepted R18 common downlink and Heartbeat cadence are
operating after a fresh reconnect, and the Heartbeat gap is inside the
2,500-ms limit. It does not establish a strict request-ready baseline because
pre-request `PARAM_VALUE` traffic must be zero. The sentinel frames are
consistent with the previously documented cold-boot generic-lane backlog, but
their exact producer was not independently measured in this run. COM6 was not
reopened after the capture. A new full power cycle is required before any
further live test on R18 because closing this one session can latch the R18 USB
loss-epoch fail-stop for the current boot.

## 20. Read-only preflight and R19 standard-path isolation (2026-09-25)

After the operator reported reconnection, COM3 and COM6 again matched the
pinned XIAO identities and no competing serial client was present. The new
R18-only read-only preflight opened COM6 once for approximately 30 seconds and
performed no serial, firmware, E220, or actuator write. This interval received
zero bytes and therefore stopped before any request:

- [`runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T122932016Z/summary.json`](runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T122932016Z/summary.json)
- result: `FAIL`
- `ground.raw.bin`: 0 bytes
- `request_attempted=0`; every serial-write flag: false
- COM3 opened: false; cleanup: PASS

This interval is not a valid contradiction of the earlier fresh-boot R18
1,244-byte baseline. Closing the earlier COM6 session can stop the accepted R18
Ground for that boot, and a one-sided reconnect can also leave Ground and
Vehicle with different TDD sessions. The next physical comparison therefore
requires one simultaneous cold boot of both XIAOs plus Pixhawk/external power,
followed by one uninterrupted capture. No second COM-open interval from that
same boot may be used as an independent control.

The runner was repaired test-first so a future preflight timeout preserves its
last observation instead of writing `preflight: null`. The saved fields now
include raw/valid frame counts, primary Heartbeat count and gap/age, unsolicited
`PARAM_VALUE` count, parser/noise/CRC/partial counts, OS RX/TX queues, and the
maximum pump service gap. Verification results are:

- R18 runner contract: 24/24 PASS
- R18 offline behavioral test: PASS
- R19 shared-runner regression: PASS
- runner SHA-256:
  `64A7DF1AE03CC111C5C9C44D2408AB58F613E78C312244473D62997A9617B7EA`

The sealed R19 candidate artifact was also audited. Vehicle/Ground roles,
candidate compile flag, pins, binary hashes, flash targets, write/readback, and
re-enumeration form a consistent provenance chain. No role swap or missing
`VC_LORA_R19_HIGH_SPEED_CANDIDATE=1` was found. Runtime self-identification is
still unavailable, so this excludes a packaging error but not a runtime
fail-close.

A new offline regression `IT-HS-CANDIDATE-STANDARD-001` was added RED-first and
then implemented with the enabled Ground adapter, TDD demux, MAVLink parser,
and radio-writer arbiter. Over 100 cycles / 100,000 ms equivalent it recorded:

- Heartbeats: 100/100
- accepted Grant observations returning `Ready`: 100/100
- standard writer physical-tail releases: 100/100
- candidate product-route events: 0
- adapter/writer fail-close: 0; final writer state: idle
- injected all-Heartbeat drop: correctly classified `RX0` while Grant/writer
  remained 100/100 healthy
- focused related tests: 15/15 PASS; complete host suite: 280/280 PASS

Evidence:

- [`runs/IT-HS-CANDIDATE-STANDARD-001/red/summary.json`](runs/IT-HS-CANDIDATE-STANDARD-001/red/summary.json)
- [`runs/IT-HS-CANDIDATE-STANDARD-001/green/summary.json`](runs/IT-HS-CANDIDATE-STANDARD-001/green/summary.json)
- [`tests/host/integration/r19_candidate_standard_path_tests.cpp`](tests/host/integration/r19_candidate_standard_path_tests.cpp)

Thus the platform-neutral R19 adapter/demux/parser/writer components do not
reproduce the zero-downlink fault. The remaining unproven boundary is the
Arduino `setup_bridge()/loop_bridge()` orchestration together with
`E220WriteContract`, AUX timing, and actual `HardwareSerial` scheduling. The
next R19 diagnostic must latch the first fail-close reason at this boundary
before another candidate HIL is meaningful.

Jev was not called for these physical results. The latest R19 run has zero
received bytes and no request/completion/Heartbeat measurements, while the
latest R18 read-only failure is from a different boot and firmware scope.
Combining them would fabricate one `r19-jev-input-2` record. Under the current
fixed gate this is `EVIDENCE_REQUIRED`, not `AMBIGUOUS`; current-run Jev input,
output, cost, and tokens therefore remain zero. The earlier synthetic live
Jev smoke remains only an API integration proof.

### Fresh simultaneous R18 cold-boot control

Both XIAOs and Pixhawk/external power were subsequently removed together for
more than five seconds. No serial ports remained enumerated during the OFF
interval. After reconnecting Pixhawk/E220, Vehicle XIAO, and Ground XIAO, the
fixed COM identities returned and no competing client was present. The repaired
read-only preflight then passed in one uninterrupted COM6 interval:

- [`runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T125041093Z/summary.json`](runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T125041093Z/summary.json)
- result: `PASS`
- raw bytes: 329; valid MAVLink2 frames: 3
- primary 1/1 Heartbeats: 3
- maximum observed Heartbeat gap: 130,231 us
- last Heartbeat age: 31,192 us
- unsolicited pre-request `PARAM_VALUE`: 0
- CRC errors: 0; partial bytes: 0; OS RX/TX queue: 0/0
- request attempted/writes: 0/0
- firmware/E220/actuator writes: 0
- cleanup: PASS; serial open after cleanup: false

The 266 parser-noise bytes are exactly one complete ESP32-S3 ROM cold-boot
banner beginning `ESP-ROM:esp32s3-20210327` and ending at the application entry
address. They are not RF-frame corruption. This fresh simultaneous cold-boot
control supersedes the intervening asymmetric/same-boot zero-byte interval and
re-establishes the accepted R18 common path as healthy. Because COM6 was closed
at the end, no further R18 live interval may be treated as independent evidence
without another full power cycle.

## 21. R19 runtime fail 診断統合と次回実機境界 (2026-09-25)

### 21.1 現在の実機基準

直近の有効な実機基準は、両XIAOとPixhawk／外部電源を同時にcold boot
した後のaccepted R18 read-only preflightである。

- [`runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T125041093Z/summary.json`](runs/hil/R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/LIVE-20260925T125041093Z/summary.json)
- result: `PASS`
- 329 RX bytes、valid MAVLink2 3 frames、primary Heartbeat 3 frames
- Heartbeat最大間隔: 130,231 us、最終age: 31,192 us
- unsolicited `PARAM_VALUE`: 0
- CRC error、partial byte、OS RX/TX queue: すべて0
- request、serial write、firmware／E220／actuator write: すべて0

従ってaccepted R18で共通hardware／RF downlink経路が成立することは確認済みである。
ただし、これはR19診断版のlive動作を証明するものではない。

### 21.2 R19製品loopのoffline確認

R19を有効にした実際の`setup_bridge()`／`loop_bridge()`を使用するhost harnessでは、
Ground／Vehicleともにruntime fail-closeを再現しなかった。これはplatform-neutralな
mock I/O上の結果であり、実ESP32、USB CDC、UART、AUX、E220のlive証明ではない。

- Ground:
  [`runs/IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001/green-40s/summary.json`](runs/IT-R19-GROUND-PRODUCT-LOOP-COLD-BOOT-001/green-40s/summary.json)
  - 40,000 ms、40,006 loops
  - Heartbeat injected 40／USB受信36、最大間隔2,100 ms
  - Grant 1、`UL_IDLE` 1、radio TX 32 bytes
  - writer physical tail 550 ms、`runtime_fail_closed=false`
- Vehicle:
  [`runs/IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001/summary.json`](runs/IT-R19-VEHICLE-PRODUCT-LOOP-COLD-BOOT-001/summary.json)
  - 706 loops
  - Pixhawk Heartbeat取込みとradio転送を確認、radio TX 32 bytes
  - writer physical tail 550 ms、`runtime_fail_closed=false`

この結果により、残る切分け対象は実ESP32のcold bootからUSB CDC、UART、AUX、
E220までの物理境界である。Mission Plannerのparameter protocolを主因とする根拠は
現在ない。

### 21.3 first-wins runtime fail診断

診断は`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1`でのみ有効になり、通常buildでは
無効である。最初のfail-closeだけをfirst-winsで保持し、role、source line、monotonic
time、startup／E220／writer／radio-session／adapter／TDD statusおよびUSB loss epochを
固定長textへ符号化する。wire形式はMAVLink2 `STATUSTEXT` (`msgid=253`、`sysid=254`、
`compid=190`、payload 51 bytes、wire 63 bytes)で、text prefixは`R19F:`である。

Groundは完全な63-byte frameをUSBへ32+31 bytesで送信し、loss epochとflushを確認する。
Vehicleはstartup failureがUSB host接続前に発生してもpublish済みにせず保持し、
`Serial.isPlugged()`かつhost-readyになった後にCOM3へ送る。これによりboot直後の
first failureがhost attach前に失われない契約になった。RF側およびPixhawk側へ診断frameは
注入しない。

検証結果:

- focused product diagnostic: 6/6 PASS
  ([`runs/validation/R19-RUNTIME-FAIL-PRODUCT-GREEN-002/20260925T134645944Z/summary.json`](runs/validation/R19-RUNTIME-FAIL-PRODUCT-GREEN-002/20260925T134645944Z/summary.json))
- full host CTest（diagnostic runner契約を含む）: 287/287 PASS
  ([`runs/validation/R19-RUNTIME-FAIL-FULL-HOST-GREEN-004/20260925T140736000Z/summary.json`](runs/validation/R19-RUNTIME-FAIL-FULL-HOST-GREEN-004/20260925T140736000Z/summary.json))

### 21.4 Arduino compileとsealed diagnostic artifact

同一sourceから通常版と診断版をXIAO ESP32S3向けにclean compileし、いずれもPASSした。

- 通常R19 candidate (`runtime_fail_diagnostics=disabled`):
  [`runs/validation/R19-RUNTIME-FAIL-ARDUINO-DEFAULT-GREEN-002/20260925T135605277Z/default_candidate_compile.log`](runs/validation/R19-RUNTIME-FAIL-ARDUINO-DEFAULT-GREEN-002/20260925T135605277Z/default_candidate_compile.log)
  - Vehicle: flash 423,897 bytes、RAM 105,416 bytes
  - Ground: flash 394,709 bytes、RAM 68,992 bytes
- R19 diagnostic candidate (`runtime_fail_diagnostics=enabled`):
  [`runs/validation/R19-RUNTIME-FAIL-ARDUINO-DIAGNOSTIC-GREEN-002/20260925T134809418Z/diagnostic_candidate_compile.log`](runs/validation/R19-RUNTIME-FAIL-ARDUINO-DIAGNOSTIC-GREEN-002/20260925T134809418Z/diagnostic_candidate_compile.log)
  - Vehicle: flash 426,789 bytes、RAM 105,768 bytes
  - Ground: flash 397,113 bytes、RAM 69,344 bytes

公式diagnostic artifactは通常candidateとは別rootへpublishした。

- artifact ID: `20260925T135545097Z-f9c5b9c2`
- [`latest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json)
  SHA-256: `6F23D4883D4C46714A91335845041AF3D6F3877E2081513DEC90B76B09CE92A9`
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20260925T135545097Z-f9c5b9c2/candidate_manifest.json)
  SHA-256: `1D76EAA72499792065C9F62DE55168C967796BD6BB8A989EA4644F21764E2858`
- handoff SHA-256: `762E4589D6D6FB84E97730555C86362DA6978C3836DD7DBBD7B43A522805E380`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20260925T135545097Z-f9c5b9c2/final_seal.json)
  SHA-256: `1204214396603A871B6E5FEEDE797552FA255DADD0CC5B9E979195CFBE234BC4`
- Vehicle application: 426,944 bytes、SHA-256
  `75C48EBA09BFCBB66484E16C0344BEB57F7F99704B604EB9F13D4D1DE51579C7`
- Ground application: 397,264 bytes、SHA-256
  `9ABC985C76E7AC96F1AED25532DB615C910A96CDE444F4E322573AE4AFC84489`

このdiagnostic artifactは明示的に次の状態で封印されている。

```text
runtime_fail_diagnostics_enabled = true
acceptance_eligible               = false
acceptance_authorized             = false
deployment_authorized             = false
```

従って診断frameを取得できても、それ自体を製品受入PASSまたはdeployment許可へ転用しては
ならない。

### 21.5 dry-runと今回の非実機範囲

diagnostic app-only flash orchestrationのDryRunはPASSした。

- [`runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260925T140324382Z-b58979e3/flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260925T140324382Z-b58979e3/flash_record.json)
- status: `PASS_DRY_RUN_NO_PROCESS_DEVICE_OR_ESPTOOL_ACCESS`
- `device_access_attempted=false`
- `process_inventory_queried=false`
- `esptool_executed=false`
- `firmware_write_attempted=false`
- `firmware_may_have_changed=false`

dual-COM diagnostic runnerのoffline self-testも12/12 PASSで、read-only、COM3 115200 bps、
COM6 57600 bps、両portの100 ms以内公平service、63-byte `R19F` decode、provenance
fail-closeを確認した。

- [`runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001/20260925T140710980Z-601b0827/summary.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001/20260925T140710980Z-601b0827/summary.json)

このSection 21の実装・検証phaseではCOM3／COM6をopenしておらず、flash、reset、電源操作、
serial送信、E220設定変更、Pixhawk操作を実施していない。従って、ここまでのR19結果は
live hardware証明ではない。

Jevも呼び出していない。現時点は判断が曖昧なのではなく、物理診断証拠が未取得の
`EVIDENCE_REQUIRED`であるため、このphaseのJev input、output、cost、tokenはすべて0である。

### 21.6 次の実機手順と承認境界

次の操作にはoperatorの明示承認が必要である。承認後も対象は一回のdiagnostic HILに限定する。

1. sealed diagnostic applicationをapp-only `0x10000`でCOM3 Vehicle、次にCOM6 Groundへ
   書き込む。erase、bootloader、partition table、merged imageは書き込まない。
2. COM3 115200 bps／COM6 57600 bpsを同時にread-onlyで40秒間captureし、最初の有効な
   `R19F`または診断frameなしという物理事実を保存する。serial writeは0のままとする。
3. capture終了後、成否にかかわらず両roleをaccepted
   `R18-PRODUCTION-R4-ACCEPTED`へ必ずrollbackし、readbackと再enumerationを確認する。

この一回の診断完了後に初めて、R19のsilent fail-close原因をsource line／statusから限定し、
修正後の通常版で932件30秒以内、Heartbeat最大2,500 ms以下、全error 0の同時受入試験へ戻る。

### 21.7 一回限定live診断結果 (2026-09-25)

operatorの明示承認後、sealed diagnostic applicationをVehicle、Groundの順にapp-only
`0x10000`へ書き込み、両roleのwrite、explicit verify、再enumerationを確認した。

- install evidence:
  [`runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260925T141630369Z-4a9b7a69/flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260925T141630369Z-4a9b7a69/flash_record.json)
- status: `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY`
- flash record SHA-256:
  `49415BC6FE35F5D624CB8EB79ACE96589134A6E6BC71152F53FB5718DB3471B8`
- final seal SHA-256:
  `2898B5D7539F5173F280B67DB80E2F588930FE0C47066321B81DB22DE64D3CBA`

続いてCOM3 115200 bps／COM6 57600 bpsを同時に40秒間read-only captureした。

- capture evidence:
  [`runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/LIVE-20260925T141846872Z/summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/LIVE-20260925T141846872Z/summary.json)
- result: `FAIL`
- diagnostic status: `FAIL_NO_RUNTIME_DIAGNOSTIC`
- Vehicle COM3: 0 bytes、0 frames、最大service gap 56,473 us
- Ground COM6: 0 bytes、0 frames、最大service gap 54,795 us
- valid／invalid diagnostic: 0／0
- serial write calls: 0
- cleanup: `PASS`
- summary SHA-256:
  `A2575C9F962234D519AFAADA8103878DBF05E7E63E47A9F5706BDB99A75EC585`
- final seal SHA-256:
  `362DC038989813A23AB0CE8AC302CE6D235240E02836001560DFD36546B5B1DA`

この結果は、R19F source lineを取得したことも、R19が正常であることも意味しない。
確認できた物理事実は「capture窓内で両CDCから1 byteも受信しなかった」ことだけである。
Vehicle COM3はfail未発生時に無出力なのが現仕様であり、Ground COM6も完全なdownlink
MAVLink frameが到着しなければ無出力になる。従って、正常無出力、RF／TDD無進行、
fail latchなしのstall、診断送信不能をこの版では分離できない。

さらに、diagnostic install完了からcapture開始まで約56.6秒あり、一回だけのR19Fが
capture前に送られた可能性を排除できない。Groundではfail-close時にegress／commitが
非cleanのまま残ると、`r19_ground_runtime_fail_boundary_clean()`が成立せず、診断frameが
永久に待機する可能性も残る。

captureの成否にかかわらず`finally`からaccepted R18 rollbackを実施し、両roleとも
1回目でread-MAC、write、explicit verify、再enumerationがPASSした。

- rollback evidence:
  [`runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/ROLLBACK-20260925T141846872Z/flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/ROLLBACK-20260925T141846872Z/flash_record.json)
- status: `PASS_R18_ROLLBACK_COMPLETE`
- Vehicle accepted R18 SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18 SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`
- rollback record SHA-256:
  `37574E2EA0B7F3EA332BDA77DD36E5F1970A1C4806590BB13AF3FF3FA3F3E69F`
- rollback final seal SHA-256:
  `AF97A3475ED5898A5F18DD778CB44BE67193A22E887062E5D1AFF435693BAE2F`
- `power_off_required=false`

現在、両XIAOはaccepted R18へ復旧済みである。R19 diagnosticおよびR19製品版は
acceptance／deployment未許可のままである。

次の診断版は、first-fail evidenceを上書きせず、diagnostic buildだけで以下を追加する。

1. CDC接続後のrole別`ARMED/ALIVE`状態frame
2. capture窓を越えて識別できるboundedな状態frame再送
3. Ground fail-close後のclean boundary収束状態または収束不能理由

これにより、no beaconをCDC／実行境界、aliveかつdownlinkなしをPixhawk／RF／TDD無進行、
R19F受信を具体的fail-closeとして分離する。今回のsummaryはJev用
`r19-jev-input-2`の必須物理値を満たさず、固定判定は`EVIDENCE_REQUIRED`である。
従ってJev APIは呼び出さず、今回のJev input、output、cost、tokenはすべて0とする。

## 22. R19 runtime diagnostic v2 最終オフライン結果（2026-09-29）

Section 21.7の無出力原因を実機で分離できるよう、診断版限定で次を実装した。

1. Ground／Vehicleそれぞれの固定63-byte MAVLink2 `R19A` ARMED／ALIVE frame
2. 1,000 ms周期のALIVEと、物理flush完了までactionを保持するcommit規則
3. first-failを上書きしない`R19F`再送（同一snapshot、最大120 commit）
4. Ground fail-close後の既受付egress drain、logical backlog破棄、clean-boundary収束診断
5. ALIVE期限到来時の製品ingress一時停止と、未読RFを破棄しない予約処理
6. zero-byte R19A取消時のMAVLink sequence再利用
7. R19A／R19FおよびALIVE予約の絶対500 ms deadline
8. physical flush timeoutを`min(100 ms, deadline残時間)`へ制限

first-failがR19Aと競合した場合は、R19Aが0 byteなら取消して同一service内でR19Fを選択する。
1 byte以上送出済みならフレームを分割・混在させず、R19Aの完全送出とflush完了後にR19Fへ移る。
期限超過またはepoch不一致はfail-closeとし、期限後の遅延commitは成功扱いにしない。

### 22.1 test-firstおよび監査結果

追加した境界試験は旧実装で次のREDを再現し、修正後にGREENとなった。

- zero-byte staged R19AがR19Fを1 service遅らせる
- continuous product ingressでGround ALIVEがstarvationする
- nonwritable USBでALIVE予約が無期限に継続する
- R19A取消でMAVLink sequence gapが生じる
- partial diagnostic writeが絶対deadlineを越える
- deadline直前のflushへ固定100 msを渡し、関数復帰が500 msを越える

最終監査ではHIGH／MEDIUM残件0、LOW残件も上記flush残時間制限で解消した。
製品版macro-off経路は変更しておらず、診断frameをRF／Pixhawkへ注入しない。

### 22.2 最終ホスト検証

- full host CTest: 298/298 PASS
  ([`summary.json`](runs/validation/R19-RUNTIME-DIAGNOSTIC-V5-FULL-HOST-001/20260929T140100000Z/summary.json),
  SHA-256 `A0F35F6CCF9EF750EDA30CF50D7AC74D4DEF8333383B783A6DEC4173EFC96256`)
- ASan＋UBSan focused diagnostic: 14/14 PASS
  ([`summary.json`](runs/validation/R19-RUNTIME-DIAGNOSTIC-V5-SANITIZER-001/20260929T140300000Z/summary.json),
  SHA-256 `482591ACFA4E5740C85D8FBF73D8C2A8E9C4F257BB7AD8A1FCA4E4EBEC4EB22E`)
- runner offline contract: 38/38 PASS
- COM open、serial write、firmware write、device access、Jev API call: すべて0

### 22.3 最終sealed artifacts

通常製品版（診断無効）：

- artifact ID: `20260929T140923296Z-8b38a867`
- manifest SHA-256: `51226B24002A3CE15EAB7D59E7F7F26E955A7129F1E908F49E27B69D212BC650`
- final seal SHA-256: `623FFFB670963CBD0579117098E055B23F901C8593C341C11D3EA4E26E1601F3`
- Vehicle: flash 423,897 bytes、RAM 105,416 bytes、application 424,048 bytes、
  SHA-256 `270F828FD7912D854A8DBE0D0C6BFE8D95DA7E09BE268AA44EF332E827DBFF74`
- Ground: flash 394,709 bytes、RAM 68,992 bytes、application 394,864 bytes、
  SHA-256 `3357E06A085E51EB4DC3B36553BC3D5572CDF119A286F94C3A20D4F2AFF9DCF2`
- [`candidate_manifest.json`](runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/20260929T140923296Z-8b38a867/candidate_manifest.json)

診断版（診断有効、HIL限定）：

- artifact ID: `20260929T141205180Z-46360cf1`
- manifest SHA-256: `E59A7D455CC9FA8FC18F2BD4C3C5A71A130DA05137EF6AC8B615A87710319348`
- final seal SHA-256: `34A26DBD66C22C17725C3FD94C2626D33D6F99BEBA77DF9E1CBB78794B62E46B`
- Vehicle: flash 429,097 bytes、RAM 106,160 bytes、application 429,248 bytes、
  SHA-256 `1BAE1209C2FEABA710B6E6B494EE40ECE835B6E3F96E1AC0472368F4CD6DDB7B`
- Ground: flash 400,657 bytes、RAM 69,760 bytes、application 400,800 bytes、
  SHA-256 `5D3BCF9BC7E272CAF072B3208D09D353E31C20D7903F5D85262550275E85B5DB`
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20260929T141205180Z-46360cf1/candidate_manifest.json)

両artifactとも独立verifierでPASSした。通常製品版も`acceptance_authorized=false`、
`deployment_authorized=false`であり、診断版は加えて`acceptance_eligible=false`である。

### 22.4 実機状態と次段階

このSection 22では実機操作を実施していない。COM3／COM6はopenせず、書込み、reset、
電源操作、process／device inventoryも行っていない。従って両XIAOにはaccepted R18が残っている。

総合証跡は
[`summary.json`](runs/validation/R19-RUNTIME-DIAGNOSTIC-V5-FINAL-OFFLINE-001/20260929T141500000Z/summary.json)
（SHA-256 `4606D285AD3FFDABFDA645545B976888CE1C0D91EDDFC82A86499D4939848648`）に固定した。

次のlive stepは、新しい一回限定の明示許可を受けた場合に限り、診断版application-only書込み、
COM3 115200 bps／COM6 57600 bpsの40秒read-only capture、finallyでaccepted R18へrollbackを行う。
このlive evidenceを得るまではR19受入、932件30秒、Heartbeat最大2,500 ms以下、全error 0の
実機同時達成を主張しない。新しいHIL evidenceがないため、この作業でJev APIは呼び出していない。

## 23. R19 runtime diagnostic 実機結果（2026-09-30）

ユーザーによる安全条件6項目の確認と一回限定許可に基づき、tag
`20260930T111634276Z-9ad3c110`で次の順序を実施した。

1. 診断版をVehicle COM3、Ground COM6へapplication-onlyで書込み・readback検証
2. COM3 115200 bps、COM6 57600 bpsを40秒間read-onlyで同時取得
3. `finally`相当の無条件経路で両roleをaccepted R18へ復旧・readback検証

### 23.1 実施結果

| 項目 | 結果 | 証拠 |
| --- | --- | --- |
| 診断版書込み | PASS | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/LIVE-20260930T111634276Z-9ad3c110/flash_record.json) |
| 40秒dual-COM取得 | **FAIL_NO_DIAGNOSTIC_BEACON** | [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/LIVE-20260930T111634276Z-9ad3c110/summary.json) |
| capture cleanup | PASS | 同上 |
| accepted R18復旧 | PASS（両role初回成功） | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/ROLLBACK-20260930T111634276Z-9ad3c110/flash_record.json) |

診断版書込みは両roleともwrite、digest verify、再列挙がPASSした。40秒取得ではVehicle COM3、
Ground COM6とも`raw_bytes=0`、完全frame、R19A ARMED／ALIVE、R19F、通常製品frameがすべて0だった。
最大service gapはVehicle 65,453 us、Ground 73,121 usで100 ms以内、serial writeは0、cleanupはPASSした。
CRC、部分frame、noise等のparser counterも0だが、これは入力自体が空であるための空集合PASSであり、
通信正常を証明しない。従ってR19F内容、first-fail理由、RF／TDD製品状態は今回の取得では評価不能である。

capture summary SHA-256は
`C95D9D35BAE5E0A262CCE875ED9498BF7755C42371361D6E071A9CC636ECA65A`、final sealは
`4DABC66097293C291EEE2EA6AD6E9D288D4C1790627D16CDDF8E4133CC30D528`である。

### 23.2 原因範囲

今回観測したのは破損frameではなく、parserより前のproducer／transport無出力である。
Groundでは、USB hostが書込み可能になる前にもALIVEの500 ms reservationを開始でき
（`r19_drain_ground_runtime_alive_boundary()`）、期限切れ時に
`r19_runtime_fail_diagnostic_transport_failed`を恒久ラッチする経路を確認した。
逐次flash、readback、再列挙後にCOMを開く今回の手順では取得開始前にこの期限を越え得るため、
Groundの0 byteと整合し、それを十分に説明できる。

VehicleはGround専用reservation処理を使用せず、host-ready時まで待つ別経路である。
従ってVehicleの0 byteを同じ原因とは断定しない。次版ではhost gate、transport-failedラッチ、
最初の送信試行を外部観測可能にしてから原因を限定する。

### 23.3 復旧証明と現在状態

accepted R18への復旧はVehicle、Groundとも初回でwrite、明示digest verify、再列挙がPASSした。

- Vehicle R18 SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground R18 SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`
- rollback record SHA-256:
  `70869DDF12B3A5DEF35EE5C2996D00A672AB8CB6D181F4D30F2FE4E29E2496F6`
- rollback final seal SHA-256:
  `C96E06F4DB2BBDA6A50937BFBBEDA1972135E1026A37DACBC4BFF31981FA62AC`

独立再計算でLIVE manifest 54/54、ROLLBACK manifest 52/52、SHA256SUMS、seal pointerに不一致0件だった。
全書込みはapplication-only offset `0x10000`であり、erase、bootloader、partition table、merged imageの
操作は行っていない。両XIAOの現在状態はaccepted R18へ復旧済みで、電源OFF可能である。

### 23.4 判定と次段階

総合判定は`FAIL_DIAGNOSTIC_CAPTURE_R18_ROLLBACK_PASS`である。R19受入、Deployment、932件30秒、
Heartbeat最大2,500 ms以下の合格主張は行わない。今回Jev APIは呼び出していない。

次は、Ground reservationを確認済みwritable host／clean-boundary試行後にのみ開始または再armする修正と、
Vehicle host gate／transport停止理由の診断追加をtest-firstで行う。そのoffline regressionとsanitizerを
完了後、新しい一回限定許可を得て再実機試験する。追加のfirmware変更、書込み、COM操作は現時点で未許可である。

機械可読の総合結果は
[`summary.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-LIVE-RESULT-001/20260930T111634276Z-9ad3c110/summary.json)
（SHA-256 `AA32B12243188E45604993EE8399DA643F7EF314628282E2A13D369F93A09650`）に固定した。

## 24. R19 runtime host-readyオフライン修正（2026-09-30）

Section 23のdual-COM 0 byte結果に対し、COM操作・実機書込みを行わず、次の2経路をtest-firstで修正した。

1. Groundは、COM6がpluggedかつCDC endpoint-readyになるまでR19A reservationの500 ms期限を開始しない。
   reservation開始後のbackpressure、切断、epoch変化に対するhard deadlineは維持する。
2. Vehicleは、CDC endpoint-readyに加えて正の`availableForWrite()`を取得するまでR19A/R19Fをstageしない。
   取得した容量は同一service内の`writeTxChecked()`へそのまま渡し、二度目の容量確認によるcheck/check競合を除去する。
3. diagnostic-only RAMに、最初と最後のhost gate、最初のchecked write、first-wins transport停止理由を保存する。
   R19A/R19Fの63-byte MAVLink2形式、TDD、parameter proxy、pin、baud、UART割当は変更しない。

### 24.1 test-first結果

| 対象 | RED | GREEN |
| --- | ---: | ---: |
| Ground late host attach | 4 failures | 6 checks / 0 failures |
| Vehicle pre-writable gate | 8 failures | 12 checks / 0 failures |
| Vehicle capacity check/check競合 | 9 failures | 13 checks / 0 failures |
| transport trace単体 | 20 compile errors | 197 checks / 0 failures |
| partial deadline reason | - | 3 checks / 0 failures |
| flush deadline reason | - | 6 checks / 0 failures |

全体検証は次のとおりである。

- full host CTest: **298/298 PASS**
- ASan + UBSan: **298/298 PASS**、ASan 0、UBSan 0
- Vehicle Arduino compile: PASS
- Ground Arduino compile: PASS
- default production sketchとstandard artifact: build前後のtree SHA-256一致

### 24.2 sealed diagnostic candidate

修正後の隔離診断候補は次に封印した。この候補はHIL診断専用であり、受入・Deploymentには使用できない。

- artifact ID: `20260930T130210596Z-fa06af0a`
- manifest SHA-256: `091176A22C4874E63C5E94141FB34FBE6F4F5104B3F9CDC2447322224B8E3D22`
- final seal SHA-256: `C8A972D0A80C3BBFE8FD7F53273F5186B3C8B4A06694DCA6E0CF11C02AFB8EB5`
- Vehicle application SHA-256: `FBADE6154A5A3A0E9C7BF0BFD2A746136C760320B89DDAFAABD89EA7B3D3C9E2`
- Ground application SHA-256: `FE2DC4E57D63249F0B7F402FF3825AB87E8394C4D31B8132CB8DD6F3546283CC`
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20260930T130210596Z-fa06af0a/candidate_manifest.json)

機械可読の結果と差分は次へ固定した。

- [`summary.json`](runs/validation/R19-RUNTIME-HOST-READY-OFFLINE-FIX-001/20260930T130500000Z/summary.json)
  SHA-256 `FE9E2EA32BB717E9117A86639227AC32D21C0169C6D17F7F496A514CBDA7D27F`
- [`diff.json`](runs/validation/R19-RUNTIME-HOST-READY-OFFLINE-FIX-001/20260930T130500000Z/diff.json)
  SHA-256 `F679BBFB24F51E26E668F249859A2165BDBD28B839FF483C7903966C04A50FF3`

### 24.3 現在状態と残る証明範囲

この作業ではCOM3／COM6をopenせず、serial write、firmware write、device access、電源操作、Jev API呼出しを
行っていない。両XIAOの実機状態はaccepted R18のままである。通常製品版も新規buildしていない。

追加したVehicle transport traceはRAM内証跡である。将来のdual-COM試験でも両CDCが完全0 byteの場合、
同じ無出力経路からこのRAM証跡を回収できない。従って今回のoffline PASSはGroundの早期期限開始とVehicleの
pre-writable／check-check経路を閉じたことを証明するが、Vehicle 0 byteの実機原因を確定したとは主張しない。

次のlive stepは、新しい一回限定の明示許可後にのみ、上記sealed diagnostic applicationをapplication-onlyで
書込み、COM3 115200 bps／COM6 57600 bpsを40秒read-only取得し、`finally`でaccepted R18へ復旧することである。
再度0 byteなら、CDCと独立したreadback経路を別途設計・許可する必要がある。

## 25. R19 runtime diagnostic 2回目実機結果（2026-09-30）

Section 24のhost-ready候補を一回限定許可の範囲でapplication-only書込みし、証拠ID
`20260930T140653188Z`で40秒dual-COM read-only取得を再実施した。この値の`Z`はUTCの
artifact IDであり、Section 23の`20260930T111634276Z-9ad3c110`とは別世代である。

| 項目 | 2回目結果 |
| --- | --- |
| capture | [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20260930T140653188Z/summary.json) |
| 判定 | **FAIL_NO_DIAGNOSTIC_BEACON** |
| Vehicle／Ground raw bytes | `0 / 0` |
| Vehicle／Ground complete frames | `0 / 0` |
| runner serial write | `0`（strict read-only） |
| 最大service gap | Vehicle `65,599 us`／Ground `78,211 us` |
| cleanup | PASS |

captureのsummary SHA-256は
`41F44397866AD626F03A4A145DB4FAF8EF060630C8B64EE4BA9040AF1C19C47A`、manifestは
`69BB921DD2053D6B97DA481C897C65EA2E38A6374166DE72BAB0E84ABB796AE4`、SHA256SUMSは
`C219213C50251F2583F9D5E786F3AFF5A0EBC1999D7E6E065BBDF6867AC7B70B`、final seal fileは
`0588AAD809C7F985EE85EAE8EC5D69F151D611A0E22091B2418572476ADD7D3D`である。

取得後は無条件rollback経路を実行し、
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20260930T140804219Z-f51cf7d1/flash_record.json)
を`PASS_R18_ROLLBACK_COMPLETE`として封印した。

- Vehicle accepted R18 application SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18 application SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`
- rollback record SHA-256:
  `A79EE08B5AD2EED532634FC03C38C64DC924CF1B0B7C7F8911285D88941D8F4F`
- rollback manifest SHA-256:
  `10ADABA0402C7EB38CB28F3A236D4424CB0D65C5726269D532548BEC9A22DF8F`
- rollback SHA256SUMS SHA-256:
  `C39A0C92A546297DFD65F35224F92E7C6D3B0513F29DFE509C370042C79F8EBB`
- rollback final seal file SHA-256:
  `F570CAD029AD4E96985A4DD9BF2D8069934C7C53F2608F16EBDFBD4725405E8C`

従って2回目も破損frameではなくproducerより前の0 byteであり、実機はaccepted R18へ復旧済みである。
Section 24.3の旧「次のlive step」はこの実施で完了したが、診断beaconの物理受信は未達である。

## 26. Read-only HWCDC bootstrap修正と事前オフライン結果（2026-10-03、履歴）

### 26.1 オフラインで成立した原因仮説

ESP32-S3 native HWCDCのcached `connected`は、hostによるIN packet pickup（`IN_EMPTY`）または
host OUT受信後にtrueとなる。旧診断bridgeは`bool(Serial)`／`writeTxChecked()`がtrueになるまで
最初のR19A/R19Fをqueueしなかった。一方、診断runnerは証拠を汚さないためserial OUTを一切送らない。

```text
first IN frameなし
  -> host pickup eventなし
  -> cached connected=false
  -> firmwareがfirst frameをqueueしない
  -> first IN frameなし
```

これはVehicle／Ground共通で成立するread-only CDC bootstrap deadlockであり、Section 25の両COM
0 byteを説明できる有力仮説だった。ただしSection 27の実機再試験でも0 byteが再現したため、実機現象の
十分条件または唯一の主因とみなしてはならない。Mission Planner protocol、MAVLink parser、RF、TDDより
前のproducer／native CDC境界という切り分けは維持する。

### 26.2 診断専用修正

通常製品経路を変えず、`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1`のときだけ次を追加した。

1. `writeTxBootstrapFrameChecked()`がexact 63-byteの不変R19A/R19Fをclean empty boundaryへ
   all-or-zeroでsoftware ringへ公開する。
2. TX muxでISRとdebug writerを遮断し、epoch、BUS_RESET、quarantine、plug presence、
   ring／stash／FIFOのempty条件をenqueue前後に検査する。
3. mux解放後も既存ISRが物理FIFOへ最大32 bytesずつ送るため、63 bytesは`32 + 31`でdrainする。
4. endpoint-ready前はdeadlineを0、Ground reservationをinactiveのまま保持し、ready後だけ
   500 ms deadlineとnormal checked-write／flush会計を開始する。
5. pending中のBUS_RESETは同じwire imageとMAVLink sequenceを新epochで再armする。

既存`writeTxChecked()`、`operator bool()`、macro-off product route、R18、TDD、UART、E220、
parameter順序は不変である。bootstrap APIは製品MAVLink dataに使用できず、受入またはDeployment権限を与えない。

### 26.3 test-firstおよびtoolchain検証

- Vehicle bootstrap: 11/11 PASS
- Ground bootstrap: 13/13 PASS
- diagnostic publisher: 203/203 checks PASS
- 関連runtime regression: 17/17 PASS
- independent normal CTest: 301/301 PASS、failed 0
- fresh ASan＋UBSan全suite: 301/301 PASS、failed/skipped 0、ASan 0、UBSan 0
- この旧source実行時に記録したsanitizer summary SHA-256は
  `C9830AC05D7838DC5F7513E07E736226FAAF43903B6C9C38AC3169C02242BC9D`だった。
  `runs/host_full_sanitizer_summary.json`はlatest-run正本であり、Section 28修正後に再生成済みのため、
  現在ファイルのhashはSection 28を正とする。

ローカルArduino ESP32 core 3.3.11は、既知の旧canonical pairからguarded installerで更新した。
公式cache ZIPから復元した上流backup対と、installed／canonical対をそれぞれSHA-256で固定した。

| 対象 | SHA-256 |
| --- | --- |
| installed/canonical `HWCDC.cpp` | `CA85F6E3EBF4ED57290A43B5564A05EA0187F26C35BBE82DBEF0F5E90D5711BB` |
| installed/canonical `HWCDC.h` | `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC` |
| upstream backup `HWCDC.cpp` | `C5ED5FDD05AA0DF9B74D390812643599223F96B459256718D0AD328AEABA6A8A` |
| upstream backup `HWCDC.h` | `9A7D1672193E8F512DCDB020739771D85E98EAAEF090BD080564DDA0FBBF7022` |

installed coreに対するsemantic contractは33/33 PASSである。
[`summary.json`](runs/validation/R19-HWCDC-INSTALLED-OFFLINE-001/20261003T081027658Z/summary.json)
のSHA-256は`ABAF629B0119350AF7EFAED0B985B8C73DAC161DC080D347B6311D62BE3BF9F9`である。

### 26.4 当時のsealed diagnostic candidate

- artifact ID: `20261003T081053916Z-1a760fe3`
- このartifactを公開した時点のmutable `latest.json` SHA-256:
  `FC597A29EB058ED8F029DF2157A4349D8FDB4DB66265788D48983E13795C1173`。
  現在の`latest.json`はSection 28のfresh artifactを指すため、この旧hashとの一致を期待しない。
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261003T081053916Z-1a760fe3/candidate_manifest.json)
  SHA-256: `B96EAE58FC8E46AD1017CEE0990101FAF618B334FB6E510805C945F0D94A276F`
- final seal file SHA-256:
  `CC5BA4BD8314FB7884F4493A3C560091D28B3FE87ABE3FAFB91739807E554BDF`
- Vehicle: flash `431,101`、RAM `106,232`、application `431,248` bytes、SHA-256
  `9D9697B74345427D5EE412C598E9A2C4BC6CC0F55D28906B5AD66DACE102CFC8`
- Ground: flash `402,757`、RAM `69,832`、application `402,912` bytes、SHA-256
  `8F1EB045B647A2CCC8F2363911E34B85E15E046DA3AB18E01384F660E39D33C1`
- sealed HWCDC semantic contract: PASS、33 checks
- `hardware_interaction.performed=false`
- `acceptance_eligible=false`
- `acceptance_authorized=false`
- `deployment_authorized=false`

candidate builderと独立verifierはともにPASSした。2026-10-03工程ではCOM列挙／open、serial write、
flash、reset、電源、RF、Jev APIを実施していない。従って両XIAOはSection 25で復旧したaccepted R18のままである。

本節時点の次手順は、新しい一回限定の明示許可がある場合だけ、このcandidateをapplication-onlyで書き、
40秒dual-COM read-only captureを行い、結果に関係なく`finally`でaccepted R18へ戻すことだった。
この手順はSection 27で実施済みであり、同じcandidateを次候補として扱わない。

本節の機械可読な総合結果は
[`summary.json`](runs/validation/R19-READ-ONLY-CDC-BOOTSTRAP-OFFLINE-001/20261003T082257493Z/summary.json)
へ固定した。SHA-256は
`E467483ECE7F45F8992A65BD464C5986EF824B88E7C87DAEC2DDABA619D54811`であり、参照する15証拠hashは再計算一致した。

## 27. 旧bootstrap候補の3回目実機結果（2026-10-03）

ユーザーが確認した実機許可と安全条件の範囲で、run ID
`20261003T083253345Z-5fc0094a`を次の順に完了した。この一回限定許可は消費済みである。

1. Section 26のsealed diagnostic candidateをVehicle、Groundへapplication-onlyで書込み、
   readbackおよび再列挙を確認
2. COM3 `115200 bps`／COM6 `57600 bps`を40秒同時にstrict read-only取得
3. 成否に関係なく両roleをaccepted R18へapplication-onlyで復旧し、readbackおよび再列挙を確認

| 工程 | 判定 | 正本 |
| --- | --- | --- |
| 診断版install | PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T083253345Z-5fc0094a-install/flash_record.json)、SHA-256 `61B8FFAE40EC541C74C1F44AFD001E7F0049301181700A2BA24A74C539ADCE1B` |
| 40秒dual-COM capture | **FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON** | [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T083253345Z-5fc0094a/summary.json)、SHA-256 `81A98B767180F3E65E97FA6F6DFDBA555370F4694021175F0B3255C458DB5238` |
| accepted R18 rollback | PASS_R18_ROLLBACK_COMPLETE | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T083253345Z-5fc0094a-rollback/flash_record.json)、SHA-256 `8ABD10AB528033A00CA99B211B02B0B1BA236F647B2EB42791E9FE6D83244E69` |

Vehicle COM3は`raw_bytes=0`、`frame_count=0`、最大service gap `66,228 us`、Ground COM6は
`raw_bytes=0`、`frame_count=0`、最大service gap `62,095 us`だった。R19A ARMED／ALIVE、R19F、
通常frameはすべて0で、serial writeも0、parser／CRC／partial／noise errorは0、cleanupはPASSだった。
従ってfailure boundaryは引き続きparser、RF、TDD、Mission Plannerより前の共通CDC producer／startup／interrupt
境界である。Section 26のcached-connection循環だけを修正しても物理beaconは出ず、旧原因確定は成立しない。

capture、install、rollbackの独立再監査では、それぞれ14/14、54/54、52/52のhash／size／seal照合が
一致した。capture生成時だけ`final_seal.sha256` sidecarが欠けていたため、live結果自体を変更せずrunnerへ
sidecar生成契約をtest-firstで追加した。契約正本は
[`summary.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-RUNNER-CONTRACT-001/20261003T090446105Z-98dcdefa/summary.json)
である。

rollback後のapplication SHA-256はVehicle
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。両COMのPnP状態もOKで、
両XIAOの現在状態はaccepted R18である。R19 acceptance／Deploymentは未許可のままである。

## 28. false-SOF／explicit ZLP kick診断修正（2026-10-03、封印時点offline-only）

Section 27の0 byteに対し、実機へ触れず、診断macroが有効な場合だけ次をtest-firstで修正した。

1. bootstrap enqueueを`usb_serial_jtag_is_connected()`／`Serial.isPlugged()`のtrueでhard gateしない。
   reset、quarantine、epoch、writer排他、clean ring／stash／FIFO、exact 63-byteは引き続き必須とする。
2. 許可された`IN_EMPTY` ISRがhost pickupを観測して立てたcached `connected`を、reset／quarantine検査後の
   診断用host witnessとして保持し、後続のfalse SOF sampleだけで0 byte gateへ戻さない。
3. bootstrap postcheck成功後、publication fence解除と`IN_EMPTY` enableに続けて
   `usb_serial_jtag_ll_txfifo_flush()`を明示的に実行し、clear済みpending edgeへ依存せず最初のhost IN
   transactionを起動する。
4. bridgeはraw `host_plugged`と独立に`bool(Serial)`と`availableForWrite()`を観測し、false-SOF cold startでも
   exact 63-byte bootstrapを試行できる。物理完了はcached pickup、empty ring／stash、FIFO pickup、epoch、
   reset／quarantine不変条件を満たした場合だけ認める。

false-SOFを開始条件にしたVehicle／Ground隔離試験はREDを確認後にGREENとなり、source semantic contractも
PASSした。現行canonical／installed `HWCDC.cpp` SHA-256は
`BF704FF26CFA8D023C9EE08995C60CDFAC09F91E40E49F53D0239639937BC0E8`、`HWCDC.h`は
`1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC`で一致している。

この変更の資格確認は**offline-only**で実施し、Section 26の旧candidate／binary／実機結果へ遡及適用しない。
fresh diagnostic candidateは次へ封印し、独立verifierもPASSした。

- artifact ID: `20261003T091702033Z-e3aa5200`
- [`latest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/latest.json)、SHA-256
  `B8F1E11C596F000E3639A8A344D072EB22679F1C09101C84A80FF35AB9C0BE81`
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261003T091702033Z-e3aa5200/candidate_manifest.json)、SHA-256
  `0836246D655F1F03CF391DC0C7BC1D74C858A4F508ED12F5F33842825318515A`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261003T091702033Z-e3aa5200/final_seal.json)、SHA-256
  `A2D1433442E9A6BD4D0A242E4F491C46F9898E405FB3FF84E1A1C8DB40254B71`
- Vehicle application SHA-256:
  `9B4D559C105EDB5A12F657FAC9AC0F631E0EE1379B29A6C86A9A8FF04E19A2CE`
- Ground application SHA-256:
  `D191D50F38A5CBD87F1995DD83754EB727CE68EEB8E92EC4D7C6FBA8FEF619EF`
- normal 301/301、fresh ASan＋UBSan 301/301、HWCDC semantic 33/33、installer `-CheckOnly`: PASS
- [`host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)、SHA-256:
  `17376F41B827A562EB4C65D44FC5DDB6DA229FF1D366B23FD8D6A4ECBB36004C`
- `hardware_interaction.performed=false`、opened COM 0、flash false
- `acceptance_eligible=false`、`acceptance_authorized=false`、`deployment_authorized=false`

このcandidateは封印時点では未flashだった。後続のSection 29で一回限定HILに使用し、試験後は両XIAOを
accepted R18へ復旧した。candidate manifestの`hardware_interaction.performed=false`はpackage生成時の事実であり、
後続HILの有無は別のinstall／capture／rollback証跡で管理する。

## 29. false-SOF／explicit ZLP kick候補の実機結果（2026-10-03）

一回限定許可でartifact `20261003T091702033Z-e3aa5200`をapplication-only `0x10000`でVehicle→Groundへ
書き込み、COM3 `115200 bps`／COM6 `57600 bps`を40秒read-only取得した。その後、取得結果に関係なく
外側`finally`からaccepted R18へ復旧した。run IDは`20261003T094504443Z-32368ca4`で、この許可は消費済みである。

| 工程 | 判定 | 正本 |
|---|---|---|
| 診断版install | `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY` | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-install/flash_record.json)、SHA-256 `153C5D81BEFE954F4F299EFAEAA7C449352BABBC58C9B3E720D99FED4F928BC5` |
| 40秒dual-COM capture | **`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`** | [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T094504443Z-32368ca4/summary.json)、SHA-256 `D99C885AEFD2A6CB68448A1225DA506D1D6FE694637395A57B520B036826718B` |
| accepted R18 rollback | `PASS_R18_ROLLBACK_COMPLETE` | [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-rollback/flash_record.json)、SHA-256 `150F5E64944BCD11E0E4EC5F7B2335A3184D1F884B51D9853BBBD8DE842D15EC` |

Vehicle COM3は`raw_bytes=0`、`frame_count=0`、R19A／R19F 0、最大service gap `98,532 us`、Ground COM6は
同じくすべて0、最大service gap `50,185 us`だった。serial writeは0、cleanupはPASSである。parser errorは0だが、
入力自体が0 byteなのでparser正常の物理証明にはならない。RF／TDD／Mission Planner層へ証拠が到達しておらず、
それらを原因または正常と判定することもできない。

install、capture、rollbackのmanifest／SHA256SUMS／final seal／sidecarは独立再計算で全件一致した。rollbackは
Vehicle／Groundとも初回でwrite、verify、再列挙がPASSし、現在のapplication SHA-256は次である。

- Vehicle accepted R18: `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18: `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`

従ってfalse-SOF／explicit ZLP kick修正も実機0 byteを解消する十分な修正ではない。R19 acceptance、Deployment、
932件30秒は未許可・未合格のままである。判定が`EVIDENCE_REQUIRED_NO_BEACON`へ一意に固定されたため、このrunで
Jev APIは呼び出していない。次は同じartifactを再flashせず、共通early-boot／診断publisher／HWCDC／USB IN境界を
CDC自己報告に依存しない証拠でoffline分離してから、新artifactを作成する。

## 30. CDC payload witness・JTAG stage record・新候補（2026-10-03、offline-only）

### 30.1 CDCの対象範囲と現在の原因判定

ここでいうCDCは、PCのCOM3／COM6とXIAO ESP32-S3 native USBを結ぶ仮想シリアル経路である。
Pixhawk D6／D7 UART、XIAO–E220 UART、LoRa RF、TDD、Mission PlannerのMAVLink処理とは別の層である。

Section 29の両COM 0 byteはこのCDC出力境界で観測された。ただし同じPC、USB、XIAOでaccepted R18の
書込み、readback、再列挙、通信が成立するため、ケーブルやPCシリアル全体の物理故障は現証拠の主因ではない。
R19固有のsetup／loop到達、CDC ready判定、最初のpayload公開、USB IN pickup／flush境界を優先して疑う。

### 30.2 payload-pickup witness修正

旧HWCDC診断経路では、cold start用のempty／ZLP kickに対する`IN_EMPTY`だけでもcached `connected=true`に
なり得た。その場合、実payloadをhostがpickupしていないのにbridgeがbootstrap待機を外れ、COM readerが開く前に
500 msの絶対期限を開始してterminal failとなる可能性があった。

診断macroが有効な場合だけ、non-empty FIFO payloadをflushした`tx_payload_in_flight` witnessを保持し、後続の
`IN_EMPTY`でそのpayload pickupを観測した場合に限ってcached connectedを成立させるよう修正した。BUS_RESET、
task discard、stash clearではwitnessを消去する。macro-offでは従来のquarantine条件だけとなり、通常製品挙動は
変更しない。canonical／installed coreのSHA-256は次で一致している。

| 対象 | SHA-256 |
|---|---|
| `HWCDC.cpp` | `9524B055A6000278399EDAC8B28854BEDCCEF3D9795C2095BFC0B00704F0BE6C` |
| `HWCDC.h` | `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC` |

このwitnessはUSB peripheral側のhost IN pickupまでを証明する。Windowsのユーザー空間COM readerが実際に
readしたことまでは証明しないため、実機改善の判定にはdual-COM captureが必要である。

### 30.3 CDCに依存しないruntime stage record

診断macro限定で、固定名`vc_lora_r19_runtime_stage_record`、固定68 bytes（17 × 32-bit）の記録を追加した。
ESP32-S3 buildの`-mdisable-hardware-atomics`を実Arduino compileで検出したため、`std::atomic`は使用せず、
single firmware task writer、aligned volatile 32-bit words、active-writer＋odd/even sequenceの契約にした。
ISRまたは別taskからmutation APIを呼ぶことは禁止し、JTAG readerはactive writerが0かつ同じ偶数sequenceを
2回観測したsnapshotだけを採用する。

記録する境界はsetup開始、`Serial.begin`復帰、cadence、identity、E220 profile、startup許可、normal mode、
high-speed adapter、setup完了、loop進入、host gate、frame stage、write attempt／accepted、flush完了、
exact-frame再開回数、最初のtransport failureである。record自体はCDC、E220、Pixhawkへ送信しない。

sealed ELFでのシンボル配置は次である。

| role | address | size | section type |
|---|---:|---:|---|
| Vehicle | `0x3fcab470` | `0x44`（68 bytes） | `B` |
| Ground | `0x3fca2690` | `0x44`（68 bytes） | `B` |

### 30.4 オフライン資格確認

| 試験 | 結果 |
|---|---|
| runtime stage record unit | 36 checks、0 failure |
| R19 product source contract | 23 checks、0 failure |
| normal host suite | 303/303 PASS |
| fresh ASan＋UBSan suite | 303/303 PASS、ASan 0、UBSan 0、skipped 0 |
| 診断ON Vehicle compile | PASS、flash `431,785`、RAM `106,296` bytes |
| 診断ON Ground compile | PASS、flash `403,425`、RAM `69,904` bytes |
| 診断OFF Vehicle compile | PASS、flash `423,917`、RAM `105,416` bytes |
| 診断OFF Ground compile | PASS、flash `394,729`、RAM `68,992` bytes |
| HWCDC integrity／installer／candidate packaging | PASS |

stage統合のRED／GREEN、diff、summaryは
[`R19-RUNTIME-STAGE-INTEGRATION-001`](runs/validation/R19-RUNTIME-STAGE-INTEGRATION-001/20261003T-stage-record/)
に保存した。fresh sanitizer正本は
[`host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)で、SHA-256は
`CC2C4A4D26792832D978817D33B529E65A6E40DC62F8BF0710A345810F440FEA`である。

### 30.5 sealed diagnostic candidate

- artifact ID: `20261003T110913332Z-04fb913b`
- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261003T110913332Z-04fb913b/candidate_manifest.json)、SHA-256
  `9C75FC105C59A7B4D9D831A557AEB9E468B2BBB6DDFC50AD7B6677099C184E91`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261003T110913332Z-04fb913b/final_seal.json)、SHA-256
  `34D8D0713E2B4C8BD69B2A44E6BD98A04F0577A6BA8279F8259C1B8A805FAB51`
- Vehicle application SHA-256:
  `45126943A21D06BB28071B3975BF01B4F1023638839555C433E7B5A004CA0E12`
- Ground application SHA-256:
  `51D8891F093FC3A1F637570909AAADBE22676C59D77B302BD801FBC03394E344`
- mutable `latest.json` SHA-256:
  `F863F572218A1774BA0107F8201906E1A04A1E65A0B97FA186654A9F074456D5`
- independent verifier: PASS
- `acceptance_eligible=false`、`acceptance_authorized=false`、`deployment_authorized=false`

builderはVehicle→Groundの順でclean compileし、公開するapp-only BINとbuild-path BINのsize／SHA-256完全一致を
確認した。roleごとにELF、map、build.options.json、sdkconfig、partitions.csv、flash_argsを封印し、
`flash_args`と`partitions.csv`を意味解析してapp offsetがexact `0x10000`であることを検証した。

Section 30作成時点ではこの候補を実機へ書き込んでいなかった。その後の書込み、40秒dual-COM取得、JTAG試行、
accepted R18 rollbackはSection 31に記録する。従って本段落の後続作業状態はSection 31を正とする。

```text
WriteAccepted 未到達
  -> setup／loop／HWCDC gate／capacity側
WriteAccepted 到達、FlushCompleted 未到達
  -> USB pickup／epoch／reset側
FlushCompleted 到達、PC capture 0 byte
  -> Windows COM open／user-space reader側
```

この実機証明までは「CDC不具合を修正済み」とは判定せず、R19 30秒受入とDeploymentも未合格のままとする。

### 30.6 統合オフライン証跡

本節の原因境界、修正、試験結果、sealed candidate、制限事項、次の一回限定HIL手順は
[`summary.json`](runs/validation/R19-CDC-STAGE-DIAGNOSTIC-OFFLINE-001/20261003T111533865Z/summary.json)
へ機械可読で固定した。SHA-256は
`5FE774BE59432DF13D37CE72F99023EE088B1303982CB58F155C46C332A7FBBF`である。
ELF上の固定recordシンボル証跡は同ディレクトリの`symbol_evidence.txt`、変更と既存証跡の索引は
`change.diff`である。通常303件の完全ログ、診断OFFコンパイル、独立verifier、sealed mapを含む証跡一覧は
[`evidence_manifest.json`](runs/validation/R19-CDC-STAGE-DIAGNOSTIC-OFFLINE-001/20261003T111533865Z/evidence_manifest.json)
へ固定し、SHA-256は`21434DC954231C82F1EADCF58CE7F4DCBD75B7E136B94F2C77E08A36D181AFEE`である。
いずれもoffline-onlyであり、実機改善、受入、Deploymentの許可を意味しない。

## 31. runtime-stage HIL結果・JTAG事前gate（2026-10-03〜04）

### 31.1 一回限定runtime-stage HIL

一回限定許可によりSection 30のsealed diagnostic candidate
`20261003T110913332Z-04fb913b`をVehicle→Groundへapplication-onlyで書き込み、40秒dual-COM取得と
VehicleからのJTAG stage readを試行した。その後、外側`finally`から両roleをaccepted R18へ復旧した。

| 工程 | 判定 | 正本 |
|---|---|---|
| 診断版install | `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY` | [`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T134433143Z-e5e67585-install/final_seal.json)、SHA-256 `1D9C7E59C77F6B1FB9464E4FC1A65A4FC31104A2BF7C0A734EF7C9BB810CAA9F` |
| 40秒dual-COM capture | **`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`** | [`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261003T134432740Z-c6d2fb49/capture/summary.json)、SHA-256 `213F43FDDF0EBF75D7FB4E43894F00AB2320058314A764EA672096060CED2E91` |
| Vehicle JTAG stage read | **CPU attach前に失敗** | [`openocd-attempt-1-capture.log`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261003T134432740Z-c6d2fb49/stage_vehicle/openocd-attempt-1-capture.log)、SHA-256 `55C4AB353969C1A144263704E26E4A9BBABDC2BB3ADE3252D79115C46B02E4E8` |
| accepted R18 rollback | `PASS_R18_ROLLBACK_COMPLETE` | [`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T134433143Z-e5e67585-rollback/final_seal.json)、SHA-256 `8D1F53B7101B2A4388FBF6733D43559FC9A3ECEED7CADF360667159F43DBFE7A` |

outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261003T134432740Z-c6d2fb49/summary.json)、
SHA-256 `7BA5E1C96A36E5C44598760D79A22A5BC0F19948F598E97B0A50B69CF8B6B197`である。
COM3 Vehicle／COM6 Groundはいずれも`raw_bytes=0`、`frame_count=0`であり、serial writeは0だった。
このためruntime stage recordの内容、R19のsetup／loop到達、CDC write／flush境界はまだ判定できない。

### 31.2 JTAG失敗の再分類

当時のimmutable summaryはcleanup証明を保守的に扱い、`target_may_be_halted=true`を記録した。しかしraw logには
`libusb_open() failed with LIBUSB_ERROR_NOT_FOUND`と`could not find or open device!`だけがあり、
device open、target examine、halt、memory dumpのいずれにも到達していない。raw logと同じ
`LIBUSB_ERROR_NOT_FOUND`署名を使う修正後classifier契約では、次へ一意に分類される。

```text
status=FAIL_JTAG_USB_OPEN
device_opened=false
target_examined=false
halt_possible=false
resume_proven=false
cleanup_required=false
target_may_be_halted=false
```

旧証跡は改変せず保存し、上記はraw logの観測事実と現行classifier契約から得た訂正判定として扱う。これはstage recordが
実装されていなかったことを意味せず、PCのOpenOCD／libusbがESP32-S3 USB-JTAG interfaceを開けなかったため、
実装済みrecordへ到達できなかったことを意味する。

### 31.3 accepted R18上のread-only pre-flash gate

同じ失敗をR19書込み後に初めて検出しないため、R19 installより前に必ず実行するfail-closed gateを追加した。
実PCでaccepted R18のままread-only実行した正本は
[`summary.json`](runs/hil/R19-JTAG-PREFLASH-GATE-001/20261004T081517724Z-manual-readonly/summary.json)、
SHA-256 `EBC973C7060AC5D8070DF0E0EEF8C3EDB0258C8B9C925577D9250CD24A462F40`である。

| role | COM→parent→MI_02 | PnP状態 | 物理port chain | user-mode interface |
|---|---|---|---|---|
| Vehicle | COM3 → `90:70:69:11:81:A4` → `USB\\VID_303A&PID_1001&MI_02\\7&7131F6A&0&0002` | `Status=OK`、`Service=WINUSB`、`ProblemCode=0` | `3.2` | GUID 0、enabled interface 0 |
| Ground | COM6 → `1C:DB:D4:5A:83:80` → `USB\\VID_303A&PID_1001&MI_02\\7&2159A644&0&0002` | `Status=OK`、`Service=WINUSB`、`ProblemCode=0` | `3.4` | GUID 0、enabled interface 0 |

最終判定は**`FAIL_JTAG_WINUSB_INTERFACE_UNREGISTERED`**である。Windows PnPは両JTAG functionを正常かつ
`WINUSB`として認識している一方、ユーザー空間から列挙する`DeviceInterfaceGUID(s)`またはenabled interfaceが
両方とも存在しない。従って現時点の直接blockerはOpenOCDから見えるWinUSB/libusb interface登録であり、
XIAO／ケーブル／JTAGハードウェア故障やR19 stage到達有無は未証明である。

gateはこの段階で停止し、`firmware_install_allowed=false`、COM openなし、flashなし、target config loadなし、
halt／resetなし、target状態変更なしを記録した。OpenOCD列挙とreader preflightもinterface登録が成立するまで
実行しない。

### 31.4 実装したfail-closed制御と資格確認

- [`read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1)は`-Preflight`を追加し、interface configだけを
  loadして`transport init`で物理USB location／serial一致を確認する。full readも同じbindingを再検証してから
  target config、halt、dumpへ進む。SHA-256は
  `51D415BAAB69A83C241D4393D256CB23E89323232D3AC54508252BABA240777F`。
- [`invoke_r19_jtag_preflash_gate.ps1`](tools/invoke_r19_jtag_preflash_gate.ps1)はCOMのMI_00からexact parent、同一parent
  MI_02、driver状態、interface登録、port chain、OpenOCD enumeration、reader preflightを順に証明する。
  SHA-256は`BCC08BFCD5EB82B03880F19BB2782877EB8FFF687F2A7EACBFDE39654E67BF1A`。
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1)は
  installより前にgateを実行し、失敗時は`FAIL_JTAG_PREFLIGHT_NO_FLASH`で終了する。gateが証明した動的locationだけを
  後続readerへ渡す。SHA-256は
  `A5606CE356EE679EE1112F5EB86EC76BF616F6DFF4FAA2DD68E37CDFA9284922`。

契約試験はreader 51/51、ログ分類8/8、standalone gate、outer orchestratorがすべてPASSした。試験正本の
SHA-256は順に、
[`reader contract`](tests/arduino_compile/check_r19_runtime_stage_jtag_reader_contract.ps1)
`C7DA73D2E1F3E0511D1BD3F063ED4B93C8117F246BB464EE520532290703CEB0`、
[`classification contract`](tests/arduino_compile/check_r19_jtag_log_stage_classification_contract.ps1)
`FFEE1EA4225F8B0C7EF6883DDDDD42722EA8A12E60F022DF62F828CBB218783D`、
[`standalone gate contract`](tests/hil/check_r19_jtag_preflash_gate_contract.ps1)
`DA2C0463DC68833C83BC7FF77FC32102F6A5B17678131BEB122BFED651E5CB3C`、
[`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1)
`9846D61FE90391A5F8FFFAF6FA1986ECB3D130868F0143502A04B9299634B043`である。全host CTestも303/303 PASSである。
したがって次回のR19書込みは、JTAG事前確認が両roleで完全にPASSしない限り開始されない。

### 31.5 現在状態と次の許可境界

- 両XIAOはaccepted R18へreadback付きで復旧済みである。
- R19 acceptance、932件30秒、Deploymentはいずれも未合格・未許可である。
- 直近の一回限定R19 HIL許可は消費済みである。
- 次の変更はEspressif公式JTAG driver/interface登録の修復であり、管理者権限とUSB再列挙を伴うWindows system
  changeなので、明示許可なしには実行しない。
- 許可後も最初はaccepted R18のままread-only gateだけを再実行する。両roleのinterface、dynamic location、
  serial/location一致がPASSした後に限り、別の一回限定HIL許可を得てR19診断版を書き込む。

### 31.6 Windows USB-JTAG driver修復とPnP-only再証明（2026-10-04）

明示許可に基づき、Espressif公式`idf-env 1.1.7`のdriver module `0.4.0`から
`idf-driver-esp32-usb-jtag-2021-07-15`を取得し、署名済みINFを両XIAOのMI_02だけへ適用した。
使用した`idf-env.exe`のSHA-256は
`37DE6B93A839AAEC8B97EC6DE7BEB9FC447525A1013F5AF5BDF218E66C2B81CE`、
installed INF `C:\Windows\INF\oem227.inf`のSHA-256は
`0652254D989022A381EB91084C74A08BAF400E510CE6A2FE4C6EC834AE99EADA`である。
driver catalogとinstallerのAuthenticodeはいずれも`Valid`、signerは
`Espressif Systems (Shanghai) Co., Ltd.`である。

| role | MI_02修復結果 | interface登録 | COM側 |
|---|---|---|---|
| Vehicle | `Status=OK`、`Service=WinUSB`、`ProblemCode=0`、`oem227.inf`、port chain `3.2` | `{80869ad8-c37f-476a-a6b4-ae241c30a473}` registeredかつenabled | COM3は`usbser.inf`のまま |
| Ground | `Status=OK`、`Service=WinUSB`、`ProblemCode=0`、`oem227.inf`、port chain `3.4` | `{80869ad8-c37f-476a-a6b4-ae241c30a473}` registeredかつenabled | COM6は`usbser.inf`のまま |

PnP-only再検証の正本は
[`summary.json`](runs/hil/R19-JTAG-PREFLASH-GATE-001/20261004T135339847Z-47c5db79/summary.json)、
SHA-256 `65D8C202678651CEC17733937419CB0F2C8D80D46AEB13A919734D68D9F385B3`である。
判定は`PASS_WINUSB_DRIVER_BINDING_PNP_ONLY`で、両roleの`driver_binding_proven=true`および
`interface_registration_proven=true`を得た。一方で、これはactive JTAG接続の証明ではないため、
`active_jtag_proven=false`、`firmware_install_allowed=false`、process exit `1`としてfail-closedを維持した。

修復後の調査で、OpenOCDの`noinit`直後に`espusbjtag list_devs`を呼ぶと、未初期化のlibusb contextを
参照してWindows版OpenOCDが`0xC0000005`で終了することをArduino版とESP-IDF版の双方で再現した。
反対に`transport init`はUSB列挙だけでなくJTAG/TAP初期化とTAP resetを行い得るため、無変更を要求する
driver修復確認には使用しない。pre-flash gateのlive実行経路はPnP-onlyへ変更し、OpenOCD／reader呼出しを
install許可判定から隔離した。outer orchestratorはPnP-only PASSを受けても
`FAIL_ACTIVE_JTAG_UNPROVEN_PNP_ONLY_NO_FLASH`でinstall前に停止する。

安全修正後のSHA-256は次である。

- [`invoke_r19_jtag_preflash_gate.ps1`](tools/invoke_r19_jtag_preflash_gate.ps1):
  `853A404C816D8C9C92B609FD697763977AEDE1849E87A494AEB70FBAA38F4210`
- [`standalone gate contract`](tests/hil/check_r19_jtag_preflash_gate_contract.ps1):
  `DD143DEA7A97469592CB7EBBA4F626B4D8A53C5B5036562CBAC128E9B28F15E0`
- [`read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1):
  `E52137F51FDD90F0AA68B2169FFB8E09776A318250BC12F29EC38BBA26466C21`
- [`reader contract`](tests/arduino_compile/check_r19_runtime_stage_jtag_reader_contract.ps1):
  `C6C0059BDEE5DC04AF826721AEE88010F7922E589B1B62919C58C9809E0C3007`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `83AC559CF10DCC429D9418A2A996912245706D1F05FD377BA04D57DD70CC1918`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `50404B500B193AF1332244FACD5DECFB2AA1D890B54D8A2E3100B77C26A039A3`

focused contractはstandalone／outerともPASSした。今回、R19書込み、COM open、target config load、
active JTAG open、JTAG clock、TAP reset、CPU halt/resetは実施していない。両XIAOはaccepted R18のままである。
次段階のactive JTAG接続確認はtargetへ影響し得る別操作として扱い、改めて明示許可を得るまで実行しない。

### 31.7 active JTAG接続確認（2026-10-05 JST）

明示依頼を受け、accepted R18のまま両XIAOのactive JTAG preflightを逐次実行した。実行前のPnP-only gateでは
USBハブ経路が前回の`3.2／3.4`から`4.2／4.4`へ変化していた。COMと親MACは不変だったため、これは機器故障ではなく
USB物理トポロジーの変更である。gateは固定port chainを識別条件にせず、各roleの現在chainが一意かつ相互にdistinctで
あることを要求する方式へ修正した。現トポロジーのPnP-only正本は
[`summary.json`](runs/hil/R19-JTAG-PREFLASH-GATE-001/20261004T161856074Z-f93e25b8/summary.json)、
SHA-256 `0A86C814104B223D79F1B32FD84E818ADC61226CD26B5DED068471BA9BAB8D1F`である。

preflightは`adapter serial`と`adapter usb location`を`transport init`より前に二重指定し、open後にも
serial/locationを再読取りして一致を確認する。`transport init`はTAP reset／scanを行い得るため、旧statusの
`NO_RESET`表現を廃止し、TAP状態変更の可能性とCPU halt/system reset command未発行を別々に記録するよう修正した。
Vehicle初回はOpenOCD exit 0、serial/location/shutdown全markerを含んでいたが、CRLF末尾をparserが受理せず
runnerだけがfalse negativeになった。実ログをfixture化してRED→GREEN修正し、再試験した。

| role | 固定binding | 判定 | 正本 |
|---|---|---|---|
| Vehicle | `90:70:69:11:81:A4` / `1-4.2` | `PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND` | [`summary.json`](runs/hil/R19-ACTIVE-JTAG-PREFLIGHT-001/20261004T162553321Z-vehicle-r2/summary.json)、SHA-256 `F89E3332CD1FFB2592265E1A0F72FA27863665FFD340D34C222B8EBE945333C3` |
| Ground | `1C:DB:D4:5A:83:80` / `1-4.4` | `PASS_JTAG_PREFLIGHT_TAP_RESET_SCAN_POSSIBLE_NO_CPU_HALT_OR_SYSTEM_RESET_COMMAND` | [`summary.json`](runs/hil/R19-ACTIVE-JTAG-PREFLIGHT-001/20261004T162614546Z-ground/summary.json)、SHA-256 `B47E4C04DD044AD0C686F1B5E62B08859CC4A31892DEFDB2C21C464AA85E568E` |

両roleともrequested/opened serialおよびlocationが完全一致し、OpenOCDは2個のESP32-S3 TAPを検出した。
`shutdown_proven=true`、`process_termination_proven=true`であり、終了後の`openocd.exe`残留数と
TCP 3333／4444／6666 listener数はいずれも0だった。一方、TAPへの影響を観測していないため
`target_state_modified=null`とし、変更なしとは断定しない。

今回のactive確認ではtarget config、target memory read、CPU halt、system reset command、flash、COM openを行っていない。
従って証明できた範囲は「両USB-JTAG adapterを固定identityでopenでき、TAP chain scanと正常shutdownができる」までである。
R19診断版書込み、runtime-stage memory read、R19 acceptance、932件30秒、Deploymentは引き続き未許可・未合格である。

最終focused試験はreader 54/54、JTAG log-stage 8/8、standalone PnP gate、outer orchestratorがすべてPASSした。
次のR19診断版install＋40秒dual-COM＋runtime-stage read＋accepted R18復旧は、別の一回限定HIL許可を得た場合だけ実行する。

### 31.8 one-shot HIL outerへのfresh active-JTAG統合（2026-10-06 JST）

一回限定HILの実行準備中、既存outerはPnP-only gateの成功を正しくfail-closedで扱う一方、同一run内で
active JTAGを証明する経路を持たないため、live成功経路へ到達できないことを確認した。保存済みの31.7証跡は
USB topologyの鮮度を保証しないため再利用せず、次の順序をouterへtest-firstで統合した。

1. sealed candidate、rollback BIN、全child tool／OpenOCD toolchainのSHA-256を検証する。
2. PnP-only gateを実行し、COM3／COM6、親MAC、MI_02、WinUSB、enabled interface、現在のdistinct port chainを証明する。
3. operatorが明示した完全OpenOCD USB locationを現在のPnP chain suffixへ結合し、bus番号は推測しない。
4. Vehicle、Groundの順で同一run内にfresh reader `-Preflight`を実行し、requested/opened serial/location、
   process termination、shutdown、CPU halt/system reset command未発行を検証する。
5. 両roleがPASSした場合だけ診断版installを許可し、同じlocationを後段runtime-stage readへ引き継ぐ。
6. active preflightでhardware interaction後のterminationまたはshutdownが証明できない場合、flash前でも
   `FAIL_ACTIVE_JTAG_CLEANUP_UNPROVEN_POWER_OFF_REQUIRED`として終了する。
7. install開始後は従来どおり40秒dual-COM read-only、逐次runtime-stage read、`finally`のaccepted R18 rollbackを行う。

hardware child substitutionを防ぐため、outerは次のchildを固定SHAで検証する。

- flash／rollback child: `F0B8BAC890B77B8EA2294567049CBE95F46C23D7C55933AB267154963A20F71C`
- dual-COM capture child: `692F707D7235953E88C95560D1F0FAE6DD84EE615FE0C52B5B47637CD29ACF9F`
- runtime-stage reader: `E52137F51FDD90F0AA68B2169FFB8E09776A318250BC12F29EC38BBA26466C21`
- PnP-only gate: `853A404C816D8C9C92B609FD697763977AEDE1849E87A494AEB70FBAA38F4210`

修正後の正本SHA-256は次である。

- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `67CC82CA9921634651E737B1FAA49656CF2943C149A908FDB27B2427E847C541`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `6F82487E8AEFBF0C00683D32B87C7FDA12C89C1A9AA1AD8D20D6404788AD13F0`

focused offline結果はreader 54/54、JTAG log-stage 8/8、standalone PnP gate、outer orchestratorがすべてPASSした。
outer contractはlive schemaについても、正常証拠、schema／status／identity／location不一致、termination／shutdown不証明、
summary欠落／破損、PnP extra role／duplicate chainを検証する。

同日のread-only tool discoveryは`PASS_TOOL_DISCOVERY_NO_HARDWARE`だった。fresh PnP-only正本は
[`summary.json`](runs/hil/R19-JTAG-PREFLASH-GATE-001/20261006T142745625Z-pnp/summary.json)、
SHA-256 `7341133B59DB2A43559CDAF88DA89F9DDB9F48DCFFFFE7DC9E426C382BE11B9B`である。
VehicleはCOM3／`90:70:69:11:81:A4`／chain `4.2`、GroundはCOM6／`1C:DB:D4:5A:83:80`／chain `4.4`で、
両roleともdriver bindingとinterface registrationがPASSした。PnP-onlyなので
`firmware_install_allowed=false`は意図した値である。

この節までにR19 flash、COM open、runtime-stage memory readは実施していない。両XIAOの最後に証明された状態は
accepted R18のままである。次は当日の安全条件（Pixhawk DISARMED、推進系隔離、両E220アンテナ接続、共通GND、
3.3 V logic、parameter backup、競合serial clientなし）をoperatorが再確認した後に限り、一回限定outerを実行する。

### 31.9 一回限定HIL実行結果とcapture runner修正（2026-10-06〜07 JST）

operatorによる安全6項目確認後、fresh PnP-only gate、両role active JTAG preflight、R19診断版install、
40秒dual-COM read-only capture、runtime-stage read、accepted R18 rollbackを一回限定outerで実行した。
正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261006T145119765Z-30170c56/summary.json)、
SHA-256 `F2B2575FA6BA4FD3BF8BC5A8150D1EF3C37FFD1C2F97038A05777BDE4007D5FD`である。

| 工程 | 結果 | 補足 |
|---|---|---|
| PnP-only gate | `PASS_WINUSB_DRIVER_BINDING_PNP_ONLY` | gate単体exit 1はflash非許可を示す意図したfail-closed値 |
| Vehicle active JTAG | PASS | serial `90:70:69:11:81:a4`、location `1-4.2`、termination／shutdown証明済み |
| Ground active JTAG | PASS | serial `1c:db:d4:5a:83:80`、location `1-4.4`、termination／shutdown証明済み |
| R19診断版app-only install | `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY` | Vehicle→Ground、offset `0x10000`、readback／再列挙PASS |
| 40秒dual-COM capture | `FAIL_INVALID_RUNTIME_DIAGNOSTIC` | 後述のrunner誤判定と100 ms公平性超過 |
| runtime-stage read | 未実行 | capture証跡契約がfail-closedで拒否したため |
| accepted R18 rollback | `PASS_R18_ROLLBACK_COMPLETE` | 両roleとも1回でwrite／verify／再列挙PASS |

capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261006T145119765Z-30170c56/capture/summary.json)、
SHA-256 `00380E3E5688580F4371A31201080C0612AB306F079685ED32FD54D88389431A`である。
実測値は次のとおりであり、過去の「R19で0 byte」は再現していない。

| role | raw bytes | MAVLink frame | R19A | 通常MAVLink | parser異常 |
|---|---:|---:|---:|---:|---:|
| Vehicle / COM3 | 2,583 | 41/41 valid | ARMED 1 + ALIVE 40 | 0 | 0 |
| Ground / COM6 | 3,599 | 89/89 valid | ARMED 1 + ALIVE 40 | 48 | 0 |

serial writeは0、R19Fは0、noise／partial／bad length／bad CRC／unsupported flags／unknown definitionは全0だった。
全82診断でstartup fault、E220 fault、radio-session fault、adapter fail-closedも観測されなかった。
Vehicle／Groundともdiagnostic ordinalとdevice monotonic timeは`0..40`で欠番・重複・逆行なく増加した。

保存summaryが`alive_sequence_time_monotonic=false`とした原因は、各roleの先頭ARMEDと最初のALIVEが同じ
host `complete_us`で記録され、Windows PowerShell 5.1の非stableな`Sort-Object complete_us`が到着順`0,1`を
`1,0`へ反転したためである。wire、firmware、CDCの不良ではない。同一時刻の正順／逆順fixtureを追加して
修正前FAILを再現し、monotonic判定をparser到着順で評価するよう修正した。

独立して、100,000 us以下のservice公平性基準に対しVehicle 289,369 us、Ground 114,859 usを記録した。
旧runnerはtimed pump内でrawをWriteThroughし、診断frameごとに`Flush(true)`を伴う個別証跡保存を行っており、
測定処理自身がserial serviceを停止させ得る設計だった。そこでtimed pumpはMemoryStreamとpending frameだけを扱い、
stopwatch停止、両COM close後にraw／frame証跡をdurable保存する方式へ変更した。旧runには区間別I/O時間がないため
289,369 usの全量を個別書込みへ定量帰属はしないが、測定中の同期durable I/Oは契約上禁止した。

修正はtest-firstで行い、Windows PowerShell 5.1上で次を確認した。

- `r19a_same_read_capture_order_monotonic`: 修正前FAIL、修正後PASS
- timed dual-COM pump内の同期durable file I/O禁止: 修正前FAIL、修正後PASS
- capture body例外＋close／dispose／raw・frame保存失敗注入: 6 errorをsummary／stderr／sealへ保持してPASS
- 不均等buffer負荷をproduction read pathへ流すalternating pump: byte budget、byte完全性、synthetic 100 ms公平性PASS
- runtime-fail diagnostic runner contract: PASS
- runtime-stage outer orchestrator contract: PASS

live raw引数は`IO.MemoryStream`へ限定し、rawと各pending frameは個別に保存を試みる。途中の保存失敗後も残りの
artifact処理を継続し、capture body例外とcleanup／persistenceの全失敗をtop-level summaryへ残す。ただしoffline pumpは
schedulerとbyte budgetの回帰試験であり、実機処理時間が100 ms以下であることの証明ではない。実測公平性は次回HILで判定する。

outerは各child scriptを実際の起動境界で`FileShare.Read`のread-only lock下に置き、review済みSHA-256と
再照合した状態でだけ起動する。初期gate後にchildが変更されるTOCTOU経路はfail-closedとなり、capture summaryの
`runner_integrity.start_sha256`もreview済みcapture child SHA-256と一致しなければ受理しない。変更後のmutation fixture、
誤ったrunner hash fixture、正常fixtureはいずれもWindows PowerShell 5.1で期待どおりPASSした。子process treeの終了が
未証明ならscript lockをouter終了まで保持し、強制timeout fixtureでwrite拒否、SHA不変、明示解放後のwrite可能を確認した。

現行SHA-256は次である。Section 31.8のcapture child／outer hashは本節で置き換える。

- [`run_r19_runtime_fail_diagnostic_hil.ps1`](tools/run_r19_runtime_fail_diagnostic_hil.ps1):
  `CF2D3F9A690325541A90E6292E289276156FB577FEA08EB92F7C982DA6DB71F0`
- [`diagnostic runner contract`](tests/hil/check_r19_runtime_fail_diagnostic_hil_runner_contract.ps1):
  `14BF1ADCF7B4EE10011F7B7AF707F049230E59025FB868B0B6E45F0E1F719F4F`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `5D4ECFE92E2EA8D5EF0B024A68BE784B2DED48BAA1D4BC201E84E0A29E3422C8`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `2BFF30CE2EDEC600441AE88C3D4249D09FC6E48EE2D7033094C694A3A0637148`

rollback正本は
[`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261006T145120098Z-e16c2261-rollback/final_seal.json)、
SHA-256 `513CB9DF1B39B07707C1E1A8EE97314AEE00203612E97226CBC585A8CA1048B2`である。
Vehicle accepted R18 SHA-256は`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、
Groundは`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。
終了後、COM3／COM6は`Status=OK`、OpenOCD／flash／capture helper残留数0、TCP 3333／4444／6666 listener数0、
`power_off_required=false`を確認した。

従って現在の両XIAOはaccepted R18で安全に復旧済みである。今回の一回限定許可は消費済みであり、修正後runnerの
100 ms公平性とruntime-stage readは未実機確認である。R19 acceptance、932件30秒、Deploymentは引き続き未合格・
未許可とする。次の実機操作は、新たな一回限定許可と当日の安全条件再確認後に同じouterを再実行する。

### 31.10 修正後一回限定HIL再実行とcleanup StrictMode修正（2026-10-07 JST）

operatorの安全確認と新たな一回限定許可を受領し、read-only tool discovery、COM3／COM6状態、競合client 0、
固定tool hash一致を確認後、修正後outerを一回実行した。正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261006T222450754Z-41b492fe/summary.json)、
SHA-256 `526F5B7A666DAA7F8E0ED8DF9E28580C81F421C858D19F935CF396C7C3EB8911`である。

| 工程 | 結果 | 補足 |
|---|---|---|
| PnP-only gate | `PASS_WINUSB_DRIVER_BINDING_PNP_ONLY` | COM3／COM6 identity、MI_02 WinUSB、port chain 4.2／4.4を再確認 |
| dual active JTAG | `PASS_FRESH_DUAL_ACTIVE_JTAG_PREFLIGHT` | Vehicle／Groundともtermination・shutdown証明済み |
| R19診断版app-only install | `PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY` | 両role write／verify／再列挙PASS |
| 40秒dual-COM capture | runner後処理FAIL | capture windowとraw／frame保存は完了、後述のPS5 StrictMode例外 |
| runtime-stage read | 未実行 | capture summary契約がfail-closedとなったため |
| accepted R18 rollback | `PASS_R18_ROLLBACK_COMPLETE` | 両roleとも1回でwrite／verify／再列挙PASS |

capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261006T222450754Z-41b492fe/capture/summary.json)、
SHA-256 `518204567D97863893F33DB65955B5118DA70BADBD9DBCB146E2901362822C7D`である。manifest 55 artifactの
再計算hash不一致は0で、summary／manifest／SHA256SUMS／final-seal sidecarは全一致した。capture final seal SHA-256は
`176BAAB75D370A6FB866F2FB282B5A6D95255CEE6492D42D397DD220386B65A3`である。

| role | raw bytes | 独立再解析 | 内容 |
|---|---:|---:|---|
| Vehicle / COM3 | 0 | 0 frame | native USB CDC出力なし |
| Ground / COM6 | 3,616 | 90/90 valid | R19A 41、HEARTBEAT 40、PARAM_VALUE 2、MISSION_CURRENT 7 |

GroundのR19AはARMED 1＋ALIVE 40、ordinal／MAVLink sequenceは`0..40`で欠番・重複・逆行なしだった。
通常90 frameはnoise／partial／bad CRC／unsupported flagなしで、製品frameはsysid 1／compid 1である。従って
Pixhawk→Vehicle→RF→Ground→USBの製品pathが動作していたことは強く支持され、Vehicle 0 byteは機体全体の停止より
Vehicle native USB CDC／host reader境界へ局在する。ただしfirmware CDC gate/writeとWindows側のstale handle／open raceは、
今回runtime-stageを読めなかったため未確定である。

capture後処理FAILの直接原因は、PowerShell 5.1で次のzero-error branchが`String[]`空配列ではなく`null`になることだった。

```text
[string[]]$persistenceErrors = if (...) { ... } else { @() }
→ persistence error 0件では $null
→ StrictMode下の $persistenceErrors.Count でPropertyNotFoundException
```

例外は40秒loop、両COM close／dispose、raw／frame durable保存の後に発生しており、Vehicle 0 byteの原因ではない。
`CaptureCleanupResult`が返る前に例外となったためsummaryは分類fieldを持たず、outerもtry外で
`diagnostic_classification`を読む二次StrictMode例外となった。

修正はtest-firstで行った。

- zero-errorの成功cleanup fixtureを追加し、修正前に同じ`Count`例外を再現
- `persistenceErrors`を明示的な`String[] @()`で初期化後、error存在時だけ代入
- outerはoptionalなclassification／statusを`PSObject.Properties`経由で安全に取得
- classification欠落のearly-failure summaryがthrowせずfail-closedになるfixtureを追加
- Windows PowerShell 5.1でdiagnostic runner contractとouter orchestrator contractがともにPASS

現行SHA-256は次である。

- [`run_r19_runtime_fail_diagnostic_hil.ps1`](tools/run_r19_runtime_fail_diagnostic_hil.ps1):
  `CF2D3F9A690325541A90E6292E289276156FB577FEA08EB92F7C982DA6DB71F0`
- [`diagnostic runner contract`](tests/hil/check_r19_runtime_fail_diagnostic_hil_runner_contract.ps1):
  `14BF1ADCF7B4EE10011F7B7AF707F049230E59025FB868B0B6E45F0E1F719F4F`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `5D4ECFE92E2EA8D5EF0B024A68BE784B2DED48BAA1D4BC201E84E0A29E3422C8`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `2BFF30CE2EDEC600441AE88C3D4249D09FC6E48EE2D7033094C694A3A0637148`

rollback正本は
[`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261006T222451153Z-d96d9253-rollback/final_seal.json)、
SHA-256 `81DAD936ACC961E2E7C4529CFD10B59C2A69F5B215DCD9790D06715D63C9F811`である。
Vehicle accepted R18は`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、
Groundは`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`で、それぞれ1回で復旧した。
終了後COM3／COM6は`Status=OK`、残留OpenOCD／esptool 0、TCP 3333／4444／6666 listener 0、
`power_off_required=false`である。

この一回限定許可は消費済みである。上記offline修正は実機未確認で、Vehicle CDC 0 byteの確定原因とruntime-stage、
実測100 ms公平性、932件30秒、Heartbeat最大2,500 ms、R19 acceptance／Deploymentは未合格・未許可のままである。
次回は新たな一回限定許可と当日の安全条件確認後、同じouterを実行し、Vehicle 0 byte再発時もsealed captureが
`ALIVE_WITH_PRODUCT_TRAFFIC / PARTIAL`として契約成立した後、Vehicle runtime-stage 68 byteを取得する。

### 31.11 追加一回限定HILのUSB位置fail-closed停止（2026-10-07 JST）

operatorから新たな一回限定許可と当日の安全条件6項目確認を受領した。read-only tool discovery、COM3／COM6
`Status=OK`、競合client 0、TCP 3333／4444／6666 listener 0、現行runner／outer hash一致を確認後、outerを
一回実行した。正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261007T125245953Z-4735ab15/summary.json)、
SHA-256 `771E5C5444D89D700CCC8837FD3ACE67978B94B6015456D46B58DC05F3396BA0`である。

結果は`FAIL_ACTIVE_JTAG_LOCATION_BINDING_NO_FLASH`である。fresh PnP gateが同じ固定serialの両roleを検出したが、
現在のport chainはVehicle／COM3が`3.2`、Ground／COM6が`3.4`であり、実行引数に固定した前回位置
`1-4.2`／`1-4.4`と一致しなかった。このため書込み前にfail-closed停止した。

- 実行stepはPnP-only `jtag_preflight` 1件だけ
- active JTAG、R19 install、40秒capture、runtime-stage read、rollbackは未実行
- install step 0であるため両XIAOは実行前のaccepted R18のまま
- 終了後COM3／COM6は`Status=OK`、残留OpenOCD／esptool 0、対象listener 0
- `hardware_interaction=false`、`power_off_required=false`

自動再試行は行っていない。この一回限定実行は消費済みである。次回は新たな一回限定許可と安全条件再確認後、
fresh PnPで確認した固定serialと、OpenOCD形式の`1-3.2`／`1-3.4`を使用し、同じouterを一回だけ実行する。

### 31.12 追加HILのOpenOCD位置形式fail-closed停止（2026-10-07 JST）

Section 31.11後に新たな一回限定許可と安全条件6項目再確認を受領し、直前にCOM3／COM6 `Status=OK`、
競合client 0、対象listener 0、runner／outer hash一致を再確認した。operatorへ案内したPnP chain値`3.2`／`3.4`を
そのままouterのOpenOCD USB locationへ渡したが、outerが要求する形式は`bus-chain`であるため、全hardware step前に
`FAIL_PREFLIGHT_NO_HARDWARE`で停止した。正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261007T125613913Z-98d371c9/summary.json)、
SHA-256 `954F22A82E42FB43F86C7EC4B144C42525EC23E235FF063C8707A3F806FC53B2`である。

- failure: `Explicit Vehicle and Ground OpenOCD USB locations are required`
- steps 0、`hardware_interaction=false`、install／capture／stage read／rollbackは全て未実行
- 両XIAOはaccepted R18のまま、`power_off_required=false`
- 終了後COM3／COM6は`Status=OK`、残留OpenOCD／esptool 0、対象listener 0

offlineでouterの正規表現とPnP suffix照合を再確認し、次回候補をVehicle `1-3.2`、Ground `1-3.4`と確定した。
両値は`^\d{1,3}-\d{1,3}(?:\.\d{1,3})*$`に一致し、抽出chainはそれぞれfresh PnPの`3.2`／`3.4`と一致する。
案内値にbus prefixを含めなかったことが本停止の原因であり、firmware／JTAG／CDCの実機障害ではない。
自動再試行は行わず、この一回限定実行も消費済みとする。

### 31.13 正式USB位置でのHIL結果とtiming-only stage-read分岐（2026-10-07 JST）

新たな一回限定許可と安全条件6項目確認を受領し、Vehicle `1-3.2`、Ground `1-3.4`でouterを一回実行した。
正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261007T131334932Z-221ad183/summary.json)、
SHA-256 `AC772F4D33438FBBB257F7E92745E901DD14C2085A34CD36A11E9F32EBDB78F2`である。

両roleのactive JTAG preflightとR19診断版app-only installはPASSした。40秒captureの結果は次である。

| role | raw bytes | valid frames | R19A | product frames | max service gap |
|---|---:|---:|---:|---:|---:|
| Vehicle／COM3 | 0 | 0 | 0 | 0 | 203,592 us |
| Ground／COM6 | 3,701 | 93/93 | 42（ARMED 1＋ALIVE 41） | 51 | 187,366 us |

Groundのproduct frameはHEARTBEAT 42、MISSION_CURRENT 8、PARAM_VALUE 1で、全てsysid 1／compid 1だった。
noise、partial、bad length、bad CRC、unsupported flag、unknown definitionは全て0で、診断ordinalとMAVLink sequenceは
`0..41`で連続・単調だった。従ってPixhawk／Vehicle／RF→Groundの製品downlinkは動作しているが、Vehicle native USB
CDCは再び0 byteであり、firmware側CDC gate／writeとWindows COM3 handle／readerのどちらかは未確定である。

capture分類自体は`ALIVE_WITH_PRODUCT_TRAFFIC / PASS_ALIVE_BEACON_CAPTURED / PARTIAL`、cleanup PASS、parser clean、
invalid diagnostic 0だった。一方、両roleのservice gapが`100,000 us`基準を超えたためrunner総合結果はFAILとなり、
旧outerは`exit_result_classification_status_mismatch`としてruntime-stage readを実行しなかった。この約200 msのhost側
service gapは100 ms公平性FAILとして維持し、40秒間のVehicle 0 byteの原因とは扱わない。

capture証拠はsummary SHA-256
`AB12E4A19D4DBD542CF7B0E24CD4EC424C41A33A4CCF2AB0CA238064CB391C15`、manifest
`5B0E64BE22B5AD0F51750DAA48CD490955F16D2CA8A81F87F808FDA9514CCE20`、final seal
`6F98A68884AC65F891B855D6CF02A383950895CBB9235DBDF8F9EFD8B374D34A`で、56/56 artifactが一致した。

rollbackは両roleとも初回でwrite／verify／再列挙PASSだった。正本は
[`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261007T131335719Z-53c2ede7-rollback/final_seal.json)、
SHA-256 `6816C968E0985D82978052E4355914C2A5D25FF2D2968BF1BEEE7B714FD3477C`である。accepted R18 hashは
Vehicle `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`で、`power_off_required=false`である。

この実測を受け、outerとそのcontractだけをtest-firstで修正した。100 ms基準とcapture runnerは変更していない。
exact runner hash／provenance／cleanup／parser／monotonic／repeat contract／invalid diagnostic 0、正確な2 role、
`pump_service_limit_us=100000`、少なくとも1 roleの超過が全て成立する既知timing-only failureに限り、captureを
stage-read用証拠として許可する。unknown failure、基準内なのにFAIL、role欠落・重複、parser／cleanup／repeat異常は拒否する。
stage readに成功しても最終statusは
`FAIL_CAPTURE_TIMING_SLA_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`、exit 1としてSLA不合格を保持する。

現行SHA-256は次である。

- [`run_r19_runtime_fail_diagnostic_hil.ps1`](tools/run_r19_runtime_fail_diagnostic_hil.ps1):
  `CF2D3F9A690325541A90E6292E289276156FB577FEA08EB92F7C982DA6DB71F0`
- [`diagnostic runner contract`](tests/hil/check_r19_runtime_fail_diagnostic_hil_runner_contract.ps1):
  `14BF1ADCF7B4EE10011F7B7AF707F049230E59025FB868B0B6E45F0E1F719F4F`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `5D4ECFE92E2EA8D5EF0B024A68BE784B2DED48BAA1D4BC201E84E0A29E3422C8`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `2BFF30CE2EDEC600441AE88C3D4249D09FC6E48EE2D7033094C694A3A0637148`

Windows PowerShell 5.1でrunner contractとouter contractはともにPASS、4 scriptのparse errorは0である。現行live
summaryのread-only replayも`timing_sla_result=FAIL`のままstage-read eligibleとなった。ただし修正後outerの実機確認、
runtime-stage 68 byte、Vehicle CDC 0 byteの確定原因、100 ms公平性、932件30秒、R19 acceptance／Deploymentは未合格・
未許可である。この一回限定許可は消費済みで、次回実機操作には新たな許可と安全条件再確認が必要である。

### 31.14 timing-only分岐の実機確認とVehicle runtime-stage取得（2026-10-07 JST）

新たな一回限定許可と安全条件6項目確認を受領し、read-only tool discovery PASS後、Vehicle `1-3.2`、
Ground `1-3.4`で修正後outerを一回実行した。正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261007T134339178Z-36fca168/summary.json)、
SHA-256 `AABC9CB14F6CCD64548C626DA309C43BFCFB1F866275B3949F213D68B0B1E7BC`である。

両roleのactive JTAG preflightとR19診断版app-only installはPASSした。40秒captureは既知のtiming-only
failureとして厳密契約に合格し、修正後outerはVehicle stage readまで進んだ。

| role | raw bytes | valid frames | R19A | product frames | max service gap |
|---|---:|---:|---:|---:|---:|
| Vehicle／COM3 | 0 | 0 | 0 | 0 | 210,536 us |
| Ground／COM6 | 3,600 | 90/90 | 41（ARMED 1＋ALIVE 40） | 49 | 188,913 us |

両roleともnoise、partial、bad length、bad CRC、unsupported flag、unknown definitionは0だった。captureは
`ALIVE_WITH_PRODUCT_TRAFFIC / PASS_ALIVE_BEACON_CAPTURED`、`evidence_contract_proven=true`、
`timing_sla_result=FAIL`、`timing_sla_failure_admitted_for_stage_read=true`である。capture summary SHA-256は
`13BCACA51A48F36851C6E52A177E3B23D98B5DBB53E7C94887DB5D873058A3FC`、artifact manifestは
`A1438FE9145A2C27CBF4EAC1063B659D7E593D84F2A368E2FBBEFA95380CCCA6`、final sealは
`35E2187DC642A3294B361F42D268948D3510C696164DCC5998CBBC341C4A9080`である。

Vehicle JTAG captureはexit 0で68-byte recordを2回dumpし、両fileはbyte一致、SHA-256も共通で
`349C9375C421A39A492A563C8D2BF659D893A0E5BDFDED39704FFBA1E80180DE`だった。固定schemaでdecodeすると次になる。

- `active_writer=0`、`sequence=0x008A0232`（even）
- magic／schema／Vehicle role／diagnostic generation fingerprintは全て正しい
- `stage_mask=0x00003FFF`、最終境界は`write-accepted-before-flush`
- counters: boot 1、loop 1,886,265、publish attempt 219,847、exact-frame restart 0
- first failure: `0x54520010 / FlushFailed`
- first-failure stage mask: `0x00003FFF`
- first-failure detail: `17,485`（失敗をlatchしたmonotonic ms）

従ってVehicleはsetup、loop、host gate、frame stage、write attempt、write acceptanceまで到達し、
`FlushCompleted`だけ到達していない。COM3 0 byteの直接障害境界はMission Planner／MAVLink／RFではなく、
Vehicle USB CDCの`Serial.flushTxComplete(...)`がfalseを返した送信完了処理である。

ただし現行JTAG readerは、capture後の`poll`出力にmarker後の文字列`running`を要求する。今回OpenOCDは
両coreへのresume markerとshutdownを記録したが`running`文字列を出さず、追加cleanupではCPU0に
`not halted / Failed to prepare for resume`を返した。これは既にrunningである場合と整合するが、現行の
fail-closed証明条件を満たさないため、readerは`FAIL_CLEANUP_UNPROVEN`、outerは
`FAIL_STAGE_READ_R18_RESTORED`とした。Ground stage readは安全のため未実行である。stage summary SHA-256は
`C3391F97AE739A438A95443F63D294F6DCBB5FF475B2A60BFF1E8F37E5CA8536`である。

finally rollbackは両roleとも初回でwrite／verify／再列挙PASSだった。正本は
[`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261007T134339528Z-22015390-rollback/final_seal.json)、
SHA-256 `C2D64A92FB2376A0C155D3F6B4CC79702CBA63C978896BA8DD8364CA4F84A7C8`である。accepted R18 hashは
Vehicle `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。終了後COM3／COM6は
`Status=OK`、残留OpenOCD／esptool 0、対象listener 0、`power_off_required=false`である。

次のoffline修正対象はJTAG readerのresume証明である。各coreの`curstate`等を明示的に記録・検証し、
既にrunningのtargetへ重複resumeした際の`not halted`を曖昧に扱わず、両core running＋process termination＋
shutdownを独立に証明するtest-first修正が必要である。その後、CDC flush失敗理由を細分化する診断を追加する。
100 ms公平性、932件30秒、Heartbeat最大2,500 ms、R19 acceptance／Deploymentは引き続き未合格・未許可である。
この一回限定許可は消費済みで、追加実機操作には新たな許可と安全条件再確認が必要である。

### 31.15 JTAG各CPU curstate証明のtest-first修正（2026-10-10 JST）

Section 31.14で発生したcleanup誤判定をofflineでtest-first修正した。旧readerはmarker後1,200文字以内の
`running`／`halted`という汎用文字列を探していたため、対象CPUとの対応を証明できず、実ログではOpenOCDの
halt表示順序にも依存していた。修正後は各phase・各CPUについて次をOpenOCDから直接記録する。

```text
VC_LORA_HALT_CURSTATE_CPU0=halted
VC_LORA_HALT_CURSTATE_CPU1=halted
VC_LORA_RESUME_CURSTATE_CPU0=running
VC_LORA_RESUME_CURSTATE_CPU1=running
```

各markerは行単位で完全一致し、各CPUにつき正確に1件であることを要求する。欠落、重複、`unknown`、停止snapshot時の
`running`、resume後の`halted`、従来の汎用`target running`文字列は全てfail-closedとなる。既にrunningのtargetへ
`resume`してOpenOCDが`not halted / Failed to prepare for resume`を出す場合も、両CPUの明示的な`running`、
`shutdown command invoked`、native process terminationが全て成立した場合だけcleanup成功とする。Tcl側のresume errorは
捕捉して両stateとshutdownを必ず記録し、合否はPowerShell側で判定する。

REDではreader contractが50/63、classification contractが3/4で意図どおりFAILした。実装後のGREENは次である。

- reader contract: 63/63 PASS
- JTAG log-stage classification contract: 9/9 PASS
- outer orchestrator contract: PASS
- 変更PowerShell 5 fileのparse error: 0
- host CTest: 303 test、exit 0
- 集約済みrun artifact: 275 PASS、2 expected XFAIL、0 FAIL
- Vehicle Arduino compile: PASS（flash 390,601 byte／11%、RAM 101,920 byte／31%）
- Ground Arduino compile: PASS（flash 360,817 byte／10%、RAM 65,512 byte／19%）

Ground compileには既存経路の`vc_lora_phase6_bridge.hpp:3632`で未使用変数`disposition`の警告が1件あるが、
errorは0である。両compileのFQBNは`esp32:esp32:XIAO_ESP32S3`で、Vehicle→Groundの順に確認した。

検証正本は
[`summary.json`](runs/validation/R19-JTAG-CURSTATE-PROOF-OFFLINE-001/20261010T074256310Z/summary.json)
である。現行SHA-256は次で、Section 31.14以前のreader／outer hashを本節で置き換える。

- [`read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1):
  `6E6C6BA3F7F797E492480A92E0CE3F5712AE6E1C8C4CDBCAA3731221FD858519`
- [`reader contract`](tests/arduino_compile/check_r19_runtime_stage_jtag_reader_contract.ps1):
  `D819C088619D0616822278AA49367D7D2A0AC8ED04F3DDAE5BFDC8B9B409380A`
- [`JTAG log-stage classification contract`](tests/arduino_compile/check_r19_jtag_log_stage_classification_contract.ps1):
  `B92C487D1451EAEBCB1B5C2BCC5B1CB28AC2CFC33234460E6E7B33646156D735`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `C357165D3AF8871D1C77845811EF31D3593B9793AC46F467E6CCD3ADFFDA3AB5`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `EB0336BD2CA4B1452AB204B1EBE5CDDA20127B999FAE939555A7A8F6CA7F405E`

本節の検証は全てofflineで、COM open、flash、OpenOCD、CPU halt、実機操作は0回である。accepted R18は未変更で、
追加の一回限定許可も消費していない。修正後readerの実機証明、100 ms公平性、932件30秒、Heartbeat最大2,500 ms、
R19 acceptance／Deploymentは引き続き未合格・未許可である。次回実機操作には新たな一回限定許可と安全条件再確認が必要である。

### 31.16 修正後JTAG証明・両role runtime-stage取得（2026-10-10 JST）

一回限定許可と安全条件6項目確認を受領し、read-only tool discoveryと競合process／port確認をPASSした後、
Vehicle `COM3 / 1-3.4`（parent serial `90:70:69:11:81:A4`）、Ground `COM6 / 1-3.2`
（parent serial `1C:DB:D4:5A:83:80`）で修正後outerを一回実行した。正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T075800693Z-5ef10ffd/summary.json)、
SHA-256 `D50A175824590AD147034F7F38FD78E3B7DB1F8CE91CB6A798A257319DC48B45`である。
outerの最終結果は`PASS / PASS_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`、`power_off_required=false`である。

両roleのactive JTAG preflightとR19診断版app-only installはPASSした。40秒dual-COM captureは次の結果だった。

| role | raw bytes | valid frames | max service gap | parser／cleanup |
|---|---:|---:|---:|---|
| Vehicle／COM3 | 0 | 0 | 39,134 us | clean／PASS |
| Ground／COM6 | 0 | 0 | 39,033 us | clean／PASS |

capture分類は`NO_BEACON / FAIL_NO_DIAGNOSTIC_BEACON`であり、R19通信受入としてはFAILである。一方、両roleの
service gapは100,000 us未満、serial write call 0、noise／partial／bad length／bad CRC／unsupported flag／
unknown definitionは全て0で、close／disposeも両role PASSだった。従って今回の0 byteは以前の約200 msのhost reader
公平性超過では説明できない。原因stageを読むための証拠契約は成立し、outerは両roleのruntime-stage読取りへ進んだ。
capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T075800693Z-5ef10ffd/capture/summary.json)、
SHA-256 `246FFB4565EE505D4CCCE57CCC001BCFD0AF5B6099A7F2933C955718692E8F04`である。artifact manifestは
SHA-256 `15B2A66C7DACFD1D2EFDA78147B4B4635C416DFD669AE600A5324E4DAC3D1037`、14/14 fileのsize／hash一致、
final sealはSHA-256 `4C7080DFB40B2B6CCEF1B2196512CB6A2238ADD8573C6CB09A7A5445ADCE79A0`である。

runtime-stage読取り結果は次である。

| role | 安定取得 | 68-byte read SHA-256 | sequence | 最終境界 | first failure |
|---|---:|---|---:|---|---|
| Vehicle | attempt 1 | `AC3BC9345FED8D4E412E59D4EE1A27E3361E4360A7DDA06BF361A1415AA8489E` | 9,114,214（even） | `WriteAccepted` | `FlushFailed / 0x54520010 / detail 1610` |
| Ground | attempt 2 | `5C79FD12D4F73C21E5CF57FB51B51F60F6D7848D8F58A1919F44A27E30CA75C6` | 152,631,532（even） | `WriteAccepted` | `FlushFailed / 0x54520010 / detail 5076` |

各roleとも2回の68-byte readはbyte一致し、`active_writer=0`、`stage_mask=0x00003fff`、boot 1、
exact-frame restart 0だった。Vehicle countersはloop 2,271,937／publish attempt 4,404、Groundはloop
37,953,428／publish attempt 136,294である。Ground attempt 1は`active_writer nonzero`を検出したため、targetを
安全にresume／shutdownしてからbounded retryし、attempt 2で安定snapshotを得た。stage正本は
[`Vehicle summary`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T075800693Z-5ef10ffd/stage_vehicle/summary.json)
（SHA-256 `08EB41DEE345A4AC69374A66ED8516FC64D25888CABE5822EA8A2BB44E9178AD`）と
[`Ground summary`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T075800693Z-5ef10ffd/stage_ground/summary.json)
（SHA-256 `C3A12E8EA1170BAC575F7A80ADE2BD9D8BE7FAD9F3E0F9F3FC8B1D4BFE846ECC`）である。

Section 31.15のJTAG修正は実機でも成立した。両role・全attemptでCPU0／CPU1のhalted marker、resume後の
CPU0／CPU1 `running` marker、shutdown、native process terminationを独立に証明し、
`resume_shutdown_cleanup_proven=true`、`target_may_be_halted=false`となった。cleanup時に既にrunningのtargetへ
再resumeして出る`not halted / Failed to prepare for resume`は、各CPUの明示的`running`とshutdownが揃ったため、
曖昧な成功扱いではなく設計どおりの証明済みcleanupとして判定された。

以上から、両R19診断sketchはsetup、loop、host gate、frame stage、USB write attempt、USB write acceptanceまで到達し、
その直後の`Serial.flushTxComplete(...)`がfalseを返して`FlushCompleted`へ到達していない。現時点で確定できる共通の
直接障害境界はR19診断版のUSB CDC送信完了待ち経路である。Mission Plannerプロトコル、MAVLink解析、E220 RF、
TDD、Pixhawk、PC側dual-COM reader公平性は、この「両XIAOが同一境界で送信を中止した」事象の主因ではない。
ただし`flushTxComplete`がfalseになる下位理由（CDC configured／line state、endpoint状態、timeout／完了predicate、
ESP32 Arduino USB stackとのAPI契約）はまだ分離できていないため、特定のWindows driver又は物理故障まで断定しない。

`finally` rollbackは両roleとも初回でwrite／readback verify／再列挙PASSだった。正本は
[`final_seal.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261010T075802125Z-052342da-rollback/final_seal.json)、
SHA-256 `D897C218017C96FAAE45893492AB7A740FE34C2CC7CF9E6C120174CB6F0F0193`である。accepted R18 hashは
Vehicle `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`で、rollback manifestは52/52 file一致した。
終了後はCOM3／COM6とも`Status=OK`かつparent serial一致、残留OpenOCD／esptool／Arduino process 0、
TCP 3333／4444／6666 listener 0、COM3／COM6参照process 0である。

この一回限定許可は消費済みである。次は実機操作なしで、`flushTxComplete`の完了条件を分解する診断と、
false時にframeを失わず保持する経路をtest-firstで修正する。修正後の再書込みには新たな一回限定許可と安全条件再確認が
必要である。932件30秒、Heartbeat最大2,500 ms、R19 acceptance／Deploymentは引き続き未合格・未許可である。

### 31.17 USB CDC direct-payload bootstrapのtest-first修正（2026-10-10 JST、offline-only）

Section 31.16では両roleの40秒CDC captureが0 byteだった一方、runtime-stageは完全63-byte diagnostic frameを
`WriteAccepted`まで受理した後、共通して`FlushFailed (0x54520010)`を記録した。この実測境界と整合するsoftware
liveness gapとして、software ringへ全frameを受理しても、最初の実payload FIFO投入がempty-FIFO/ZLP要求と後続
`IN_EMPTY` interruptに依存していた点を分離した。これはofflineで特定した修正候補であり、実機0 byteの確定根本原因又は
解消済みを主張しない。

変更前に`diagnostic_bootstrap_payload_primes_fifo_before_flush`を追加した。RED正本は
[`summary.json`](runs/validation/R19-HWCDC-DIRECT-PAYLOAD-PRIME-OFFLINE-001/20261010T-red/red/summary.json)、
SHA-256 `3A605004CCE2F73A954C31EED98974A762DE728E1D17C234310AAAE980A0DCAD`で、追加した1 assertionだけが
falseとなった。

GREEN実装は`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS`限定で次を行う。

- postcheck後、完全frameを保持したpublication fence／TX mux内でBYTEBUFから最大32 byteだけ取得する。
- FIFO write直前・直後にBUS_RESET、loss epoch、quarantineを再検査する。
- real payloadをFIFOへ直接primeし、short write suffixを既存の固定64-byte stashへ保持する。
- `tx_payload_in_flight=true`を設定してからfenceを解除し、`IN_EMPTY` enable、`wr_done`の順で公開する。
- zero writeは全software streamを破棄して0 acceptedを返す。writeと競合したresetはpossibly-written FIFOも
  quarantineし、後続のclean BUS_RESETまで再利用しない。

exact 63-byte admission、all-or-zero caller acceptance、debug writer排他、reset／epoch fail-closeは維持した。
通常製品の`writeTxChecked()`と`flushTxComplete()`成功predicate、UART、ピン、TDD、E220 profileは変更していない。
canonical／installed coreのSHA-256は次で一致する。

- `HWCDC.cpp`: `FDD06A57D8B99B20C9A1484E0257BDE82D06DCE97D3C001FA61CD3C71F7F2382`
- `HWCDC.h`: `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC`

offline回帰結果は次である。

- HWCDC semantic: 35/35 PASS。bootstrap固有8件＋connected payload witnessの合計9件をcandidate manifestの
  exact required subsetとして固定した。
- product source contract: 23/23 PASS。
- low-level bootstrap model: 28/28 PASS。
- installer、Phase 6 manifest、candidate builderの各契約: PASS。新assertion欠落をfail-closedで拒否する。
- normal host CTest: 303/303 PASS、FAIL 0。
- fresh Clang 22.1.8 ASan＋UBSan: 303/303 PASS、skipped 0、ASan report 0、UBSan report 0。
  正本は[`host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)、SHA-256
  `E735036BB1672549BFE9A0F14F4A9216FFA00573CA95A5EAFFA28B2BD7FA5675`である。
- GREEN semantic正本は
  [`summary.json`](runs/validation/R19-HWCDC-DIRECT-PAYLOAD-PRIME-OFFLINE-001/20261010T-red/green-final/summary.json)、
  SHA-256 `257D8007C9EBBD2B77A9BBC4C0AF2603E0C7DD42D3D05495DC60CDFAC66A187D`である。

更新済み9項目required contractでfresh diagnostic candidate
`20261010T090523384Z-93c6076d`をVehicle→Ground順にcompileし、独立verifierでPASSした。Vehicleはflash
432,065 byte／RAM 106,296 byte、Groundはflash 403,705 byte／RAM 69,904 byteである。

- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261010T090523384Z-93c6076d/candidate_manifest.json):
  SHA-256 `C2E06148A0F274FE13D43FA2635A831BA06F5A7145A714C81A28B04B03ABBDCD`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261010T090523384Z-93c6076d/final_seal.json):
  SHA-256 `390ACB1A5A0FBC64F194A4F9B1E63144E3F16B0C80321C6999B94603E7E78459`
- Vehicle application SHA-256:
  `021EE5C610CD2E005A3C0D0236B57E9E2C3D36F530B0C0BB2660442B2820C577`
- Ground application SHA-256:
  `941BBD9BA422FDAB18D4BB3CBCCB03417EA06D997C03992D1DFE8A841DEC2FDA`

候補buildのhardware interaction、COM open、upload、flashは全て0である。accepted R18 default sketch treeは前後とも
`298210EC045A5C6FEBA6BB315E4DFE34EC9EE7FFBFF5BC947718ABF1B957386F`で不変であり、両実機のaccepted R18も
未変更である。R19 acceptance／Deploymentは未許可・未合格を維持する。

次回は新たな一回限定許可と安全条件6項目確認後にのみ、このfresh candidateを対象としてactive JTAG pre-flash gate、
Vehicle→Ground application-only install、40秒dual-COM、両role runtime-stage読取り、finally accepted R18 rollbackを
一回実施する。最初の実payloadが取得できた場合も、932件30秒とHeartbeat最大2,500 msは別の受入試験で同時確認する。

### 31.18 candidate install前の自己競合誤検出とoffline修正（2026-10-10 JST）

fresh candidate `20261010T090523384Z-93c6076d`を対象とする一回限定HILを開始し、Vehicle
`COM3 / 1-3.4`とGround `COM6 / 1-3.2`のactive JTAG preflightはPASSした。しかしcandidate install childは、
device接続前のcompeting-client検査で停止し、finallyのrollback-only childも同じgateで停止した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T093131125Z-156ac22a/summary.json)、
SHA-256 `A25891C666AE84D4279CB34806EDD8F45362A54BB7ED4D340B9F0A4A12C914BC`である。

install／rollback両recordは共通して`operations=[]`、`device_access_attempted=false`、
`firmware_write_attempted=false`、`firmware_may_have_changed=false`である。`esptool_executed=true`は
`esptool --version`だけを示す。従って本runでR19 candidate又はaccepted R18を書き込んだ事実はなく、COM open、
40秒capture、runtime-stage readも実施していない。`FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED`はrollback write失敗を
意味せず、rollback処理もdevice接続前に停止して復旧状態を当該run内で証明できなかったためのfail-closed分類である。
ユーザーによるGround／Vehicle XIAO USBとPixhawk／外部電源の5秒以上OFFは完了した。

停止の十分原因は、outer起動前確認を行った親`pwsh.exe`のCommandLineに`COM3`／`COM6`が含まれ、子flash toolが
自PIDだけを除外して全processのCommandLineを検索したため、祖先launcherを外部serial clientと誤認したことである。
一致process全行は旧成果物へ保存されていないため、他候補の完全列挙までを主張しない。

変更前に祖先／非祖先、known client、lookalike、cycle、duplicate PID、current PID欠落を含むbehavioral contractを
REDで追加した。GREEN修正では、現在processから辿れる祖先chain上の`powershell.exe`／`pwsh.exe`で、canonical outer
basenameを完全tokenとして含むprocessだけを`explicit_com3_or_com6_refs`から限定除外する。known serial client判定は
祖先でも除外せず、非祖先、sibling、名称lookalike、Python等、cycle／duplicate／current-row欠落はfail-closedを維持する。
除外対象は`trusted_launcher_ancestors`へ記録する。flash tool SHA-256は
`7375FB07F3C25CBEC3408A66BD17753E1A59B523D362A5F28C7585E29E510D34`で、outerの固定pinと一致する。

offline検証結果は次である。

- 全host CTest: 303/303 PASS、failure 0。
- host summary: 277件中275 PASS、既知XFAIL 2、unexpected failure 0。
- candidate flash contractとruntime-stage outer contract: PASS。
- 独立fail-closed監査: P0／P1指摘なし。
- default-off Vehicle compile: PASS、390,601 bytes flash／101,920 bytes RAM。
- default-off Ground compile: PASS、360,817 bytes flash／65,512 bytes RAM。
- Windows PowerShell 5.1でのread-only tool discovery: `PASS_TOOL_DISCOVERY_NO_HARDWARE`、hardware interaction 0。

OpenOCD scripts treeはWindows PowerShell 5.1で固定hashを算出する。PowerShell 7ではculture／sort実装差により同一の
1,131 fileでも異なるtree hashとなって安全停止するため、live HIL outerは手順書どおり明示的な
`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`から起動する。これは製品runtime要件ではなく、
試験証拠の再現条件である。

追記（2026-10-11）: 上記はSection 31.18時点の履歴である。Section 31.20でartifact path列を
`OrdinalIgnoreCase`順へ固定し、PowerShell 5.1／7間のtree-hash差は解消した。現在は両方で同一sealed artifactをverifyできる。

この修正はoffline限定で、R19 direct-payload prime、dual-COM、runtime-stage、932件30秒を実機では再評価していない。
直近の一回限定許可は消費済みである。次回は新規の一回限定許可と安全条件6項目の再確認後にだけ、同じsealed candidateを
Windows PowerShell 5.1から直接起動して再試験する。R19 acceptance／Deploymentは未許可・未合格を維持する。

### 31.19 並列監査による競合gate停止と失敗process証拠のtest-first固定（2026-10-10 JST）

fresh candidate `20261010T090523384Z-93c6076d`の再試験では、Vehicle `COM3 / 1-3`、Ground
`COM6 / 1-4`のactive JTAG preflightはPASSしたが、candidate installは書込み前の競合gateで
`Another process command line references COM3 or COM6`となり停止した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T112358892Z-39cbe1cf/summary.json)、
SHA-256 `223FB6251A038CEA6804B6599DF5002ECBD17DB03D5B51ADB5E11AA9BAF1142F`で、最終状態は
`FAIL / FAIL_INSTALL_R18_RESTORED`、`power_off_required=false`である。

install正本は
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261010T112359862Z-29e592dd-install/flash_record.json)、
SHA-256 `C3C3BA0E6A34123B0643085FBA0FD159D1136F0810A960CE390F1624DADB4EA7`である。
`operations=[]`、`device_access_attempted=false`、`firmware_write_attempted=false`、
`firmware_may_have_changed=false`であり、candidate書込み、40秒dual-COM capture、runtime-stage readは実行していない。
旧toolは一致process行を保存していなかったため、同時刻のread-only PnP／監査processが一時的に`COM3`／`COM6`を
CommandLineへ含んだ可能性が最も高いが、これは推定であり確定原因とはしない。製品、ハードウェア、CDC又はRFの失敗を
示す結果でもない。

finallyのrollback-onlyは両roleともattempt 1でaccepted R18のwrite、read-back verify、再列挙をPASSした。
rollback record SHA-256は`481368F703A43A98D8FB659BAF21D0BAA1E29C660D1764BC8EE0E509D0741993`、
final seal SHA-256は`F6D0E5E65334E0A69C388B393266D71E2517E6352C52405EC1A39FFC61D5E9AB`である。
従って「candidateは書かれていない」が、「最終的なaccepted R18の再書込み・検証は実施した」が正確な状態である。

この不足をtest-firstで修正した。競合がある場合だけ、throw前に改変不可かつ単調増加名の
`competing_client_gate_01.json`、`_02.json`、…を作成する。各記録は全blockerの`PID`、`ParentPID`、`Name`、
`ExecutablePath`、`CommandLine`、trusted ancestor、分類、件数、現在PID、取得・保存時刻を保持する。
`flash_record.json.competing_client_gate_failures`は各ファイルのpath、SHA-256、status、件数を参照し、通常の
artifact manifest／SHA256SUMS／final sealにも含める。clean gateは失敗証拠を作成しない。known serial clientと
exact `COM3`／`COM6` referenceのfail-closed拒否条件は一切緩和していない。

REDでは「clean gate 2回で証拠0件、異なる競合失敗2回で別々の完全証拠2件」を満たさずFAILした。GREENでは同条件、
全blocker 5項目の完全一致、path／hash参照、既存のancestor／sibling／lookalike／cycle／duplicate PID／current PID欠落
条件を全てPASSした。検証結果は次である。

- Windows PowerShell 5.1を明示しDesktop module pathを先頭にしたhost CTest: 303/303 PASS。
- candidate flash contract、runtime-stage outer contract: PASS。
- read-only tool discovery: `PASS_TOOL_DISCOVERY_NO_HARDWARE`、hardware interaction false。
- accepted R18 sketchの直接compile: Vehicle PASS（390,601 byte／11%、RAM 101,920 byte／31%）、Ground PASS
  （360,817 byte／10%、RAM 65,512 byte／19%、既知のunused-variable warning 1件）。
- 通常compile wrapperは、canonical R19診断headerとaccepted R18 sketch-local copyの意図的な差を検出して書込み前に停止した。
  本修正では両者を同期せず、production sketchを変更していない。

現行SHA-256は次である。

- [`invoke_r19_candidate_app_flash_hil.ps1`](tools/invoke_r19_candidate_app_flash_hil.ps1):
  `97CF5BF3A2DAE1065472FB93E5100FED477E4DBB9C9B1791D7FCCEE4CF171677`
- [`candidate flash contract`](tests/hil/check_r19_candidate_flash_orchestrator_contract.ps1):
  `E58706BC26A8F1C218E87E853C9533E48B51AA5912E8D2BC6F22A3F0F7E1BDEB`
- [`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1):
  `B830DFF0DF574DF42A74EF50036321ECF75DE0474682E35F9D985DF6948A9164`
- [`outer orchestrator contract`](tests/hil/check_r19_runtime_stage_cause_experiment_orchestrator_contract.ps1):
  `836A909B227F580847796867657CA78AECA3257FF1B51197F2E60BD79843AA11`

Candidate R19書込みの直近目的は、R18を修理することでも即Deploymentすることでもない。Section 31.16で実測した
`WriteAccepted -> FlushFailed -> dual-COM 0 byte`境界に対し、Section 31.17のdiagnostic-only direct-payload FIFO primeが
最初の実payloadをPCへ到達させるかを40秒dual-COMで確認し、失敗時はruntime-stageで次の境界を確定することである。
この前段がPASSした後にだけ、別のMission Planner／Pixhawk／E220受入で932/932を30,000 ms以内、Heartbeat最大
2,500 ms以下、全error 0を同時評価する。UART、E220 air rate、ピン、profileは変更せず、R19の高速化はbulk／session／
TDD利用効率の改善であり設定bps引上げではない。全診断runはaccepted R18へrollbackして終了する。

本節の修正はoffline限定で、ファームウェア、TDD、UART、E220設定、candidate binaryは変更せず、COM／JTAG／実機へ
アクセスしていない。次回live outerの開始前に全PnP／process inventoryを完了し、active JTAG開始からaccepted R18 rollback
完了まで、CommandLineに`COM3`又は`COM6`を含む並列agent、監査、terminal、read-only inventoryを開始してはならない。
追加実機操作には新たな一回限定許可と安全条件6項目の再確認が必要であり、R19 acceptance／Deploymentは未許可・未合格である。

### 31.20 HWCDC Endpoint FIFO／flush境界のJTAG診断レコード追加（2026-10-11 JST、offline-only）

Section 31.16で判明した`WriteAccepted -> FlushFailed -> dual-COM 0 byte`を下位境界へ分解するため、
`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS`限定の固定96-byte／24-word
`vc_lora_r19_hwcdc_fifo_diagnostic_record`を追加した。既存68-byte runtime-stage recordのABIとsymbolは変更せず、
通常製品経路ではこの診断recordをUSB CDC、UART、RF又はMAVLinkへ送らない。dynamic allocation、lock、spin、waitも追加していない。

96-byte recordは次を一つの安定snapshotとして保持する。

- FIFO write attempt、合計byte、zero write、直近write size
- `WR_DONE`、raw `IN_EMPTY` IRQ、payloadを実際にpickupした`IN_EMPTY`
- publish／pickup generation、loss epoch、BUS_RESET、ring／stash pending byte
- flush attempt、success、timeout、ZLP、active transaction、および会計から推定するabort
- connected、FIFO writable、payload in-flight、quarantine、reset pending、bootstrap fence／abort、debug writer、flush active
- HostAbsent、EpochMismatch、SoftwarePending、FifoNotWritable、PayloadPickupPending、Quarantined、ResetPending、Uninitializedのblocker mask

known flag maskは`0x000007FF`、known blocker maskは`0x000000FF`である。nested flush attemptは拒否し、
epoch mismatchはabortとしてactive transactionを終端する。初期化時はstale activeと全counterを消去する。
BUS_RESETと同時に観測したraw `IN_EMPTY`はIRQ countには残すが、payload pickup generationを進めない。
flush会計は`attempt = success + timeout + inferred abort + (active ? 1 : 0)`でfail-closed検証する。

[`read_r19_runtime_stage_jtag.ps1`](tools/read_r19_runtime_stage_jtag.ps1)は、CPU halt中に68-byte recordと96-byte recordを
それぞれ2回、計4回読む。ELF／`nm`のsymbol addressとsize、2回のbyte一致、magic、schema、even sequence、
`active_writer=0`、両symbolの32-bit alignment／非重複、known mask、counter、generation、flush会計を全て確認する。
[`invoke_r19_runtime_stage_cause_experiment_hil.ps1`](tools/invoke_r19_runtime_stage_cause_experiment_hil.ps1)は、その結果を
`FIFO write -> WR_DONE -> raw IN_EMPTY -> payload pickup -> flush finish`の境界分類としてouter証拠へ引き継ぐ。

installer／candidate／Phase 6 provenanceは、`HWCDC.cpp`、`HWCDC.h`、`HWCDCR19Diagnostic.h`の3ファイルを一組として
hash固定し、旧2ファイル構成からの移行と失敗時rollbackを検証する。artifact path順は`OrdinalIgnoreCase`へ固定したため、
PowerShell 5.1とPowerShell 7の双方で同じsealed candidateをverifyできる。PowerShellはPC上の試験・診断・証拠封印にのみ
使用し、XIAO製品runtime又は配布ファームウェアの実行依存ではない。

offline検証結果は次である。

- FIFO diagnostic model: 67/67 PASS。
- source contract: 32/32 PASS。
- HWCDC semantic contract: 42/42 PASS。
- JTAG reader contract: 82/82 PASS、outer orchestrator contract PASS。
- 変更対象PowerShell 13ファイル: parse error 0。
- 全host CTest: 304/304 PASS、failure 0。
- installed Arduino ESP32 coreとcanonical 3ファイル: SHA-256一致。
- default-off product compile: Vehicle→Ground順でPASS。Vehicle 390,601 byte flash／101,920 byte RAM、Ground
  360,817 byte flash／65,512 byte RAM。firmware manifest SHA-256は
  `FEF9CB4FC5CAECF2B844C92FF7912A3E2DA405CBF89F6853616A06C59D14A3AB`である。

fresh sealed diagnostic candidateは`20261011T130746575Z-da934683`で、`runtime_fail_diagnostics_enabled=true`、
`acceptance_eligible=false`、`acceptance_authorized=false`、`deployment_authorized=false`である。

- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T130746575Z-da934683/candidate_manifest.json):
  SHA-256 `BC2289D28A6E51CB9FD055503F84E9DC0F596AE527D03A6F418779AE5C7DF952`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T130746575Z-da934683/final_seal.json):
  SHA-256 `BBB76BC97EC2F11A04C8BCA470FF0E5AAC6D3B282F8657F4BD9546FB1250CF70`
- Vehicle application SHA-256: `A4F7FD6013550DFD15C4EC6DD189BFB9ABEEB00BDC7F8AA22DEFBF535F53F610`
- Ground application SHA-256: `FD05311A10CD165C9FC038DFBED6409C992097F0E3D2E6F0E99875CCC1266A5F`
- Vehicle ELF: runtime-stage 68 byte `0x3fcab470`、FIFO record 96 byte `0x3fcab7e4`
- Ground ELF: runtime-stage 68 byte `0x3fca2690`、FIFO record 96 byte `0x3fca29b8`

正本は
[`summary.json`](runs/contracts/FW-R19-HWCDC-FIFO-DIAGNOSTIC-001/20261011T132801179Z/summary.json)と
[`changes.diff`](runs/contracts/FW-R19-HWCDC-FIFO-DIAGNOSTIC-001/20261011T132801179Z/changes.diff)である。
本節の作業ではhardware interaction、COM open、OpenOCD、CPU halt、flash、uploadを一度も実行していない。
両XIAOのaccepted R18は変更していない。

ここで証明したのは「Endpoint FIFOの各境界を実機で判別できる診断機能が成立した」ことであり、
「実機のEndpoint FIFOが正常動作した」「CDC 0 byteが解消した」ことではない。次回liveは新たな一回限定許可と
安全条件6項目の再確認後にだけ、sealed candidateのVehicle→Ground application-only install、40秒dual-COM、
両roleの68+96 byte record各2回読取り、finally accepted R18 rollbackを行う。その結果で初めて、
FIFO write、`WR_DONE`、raw `IN_EMPTY`、payload pickup、flush終端のどこで止まるかを確定する。
932件30秒、Heartbeat最大2,500 ms、全error 0のMission Planner受入は、そのbootstrap診断に合格した後の別試験であり、
R19 acceptance／Deploymentは引き続き未許可・未合格である。

### 31.21 Endpoint FIFO実機診断・host-visible境界の再分離（2026-10-11 JST）

新しい一回限定許可と安全条件6項目再確認後、sealed diagnostic candidate
`20261011T130746575Z-da934683`を対象に、Vehicle `COM3 / USB 1-4`、Ground `COM6 / USB 1-3`で
active JTAG、Vehicle→Ground application-only install、40秒dual-COM、両roleの68+96 byte record各2回読取り、
finally accepted R18 rollbackを一回実行した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T134040142Z-fd5ec71c/summary.json)、
SHA-256 `3AE2786131ADFBF03EFB798BFE9B4AACF647AC8FA5601F7E26A8AE945089FE34`である。
outerは`PASS / PASS_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`、`power_off_required=false`となった。
このPASSは原因証拠取得とR18復旧の完了を示し、R19通信合格を意味しない。

40秒dual-COMは次の通信FAILだった。

| role | raw bytes | valid frames | max service gap | parser |
|---|---:|---:|---:|---|
| Vehicle／COM3 | 0 | 0 | 48,021 us | clean |
| Ground／COM6 | 0 | 0 | 48,367 us | clean |

serial writeは0、両portのclose／disposeはPASSし、statusは`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`である。
capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T134040142Z-fd5ec71c/capture/summary.json)、
SHA-256 `F97C192754B4BA6D412BF002B191C9F76CBE1B834CCD800E86D42C6ECADB085A`である。

96-byte Endpoint FIFO実測は次である。両roleとも2回の読取りはbyte同一、`active_writer=0`、magic／schema／sequence、
counter、generation、mask、flush会計、symbol非重複をPASSした。

| 項目 | Vehicle | Ground |
|---|---:|---:|
| FIFO write attempt／bytes／zero | 4／126／0 | 2／63／0 |
| `WR_DONE`／raw `IN_EMPTY`／payload pickup | 12／11／4 | 9／8／2 |
| flush attempt／success／timeout／abort | 2／1／1／0 | 5／0／5／0 |
| publish／pickup generation | 4／4 | 2／2 |
| ring／stash pending | 0／0 | 0／0 |
| BUS_RESET／quarantine／blocker | 0／false／none | 0／false／none |
| 最終USB境界分類 | `usb-tx-boundary-complete` | `flush-timeout-observed` |

Vehicle正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T134040142Z-fd5ec71c/stage_vehicle/summary.json)、
SHA-256 `8DD219A460B1DB3F0E052A5EFD2AE41F5E9FB39EA6F55E5B8185CE3B47058C3F`、Ground正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T134040142Z-fd5ec71c/stage_ground/summary.json)、
SHA-256 `7A91E60094ACEC296DAE386EEA7EC3E36E4282DB6E42E1F050B9F6E34AA9F6A1`である。

この結果により、R19 diagnostic pathがFIFOへ0 byteしか書けない仮説、`WR_DONE`／`IN_EMPTY`が全く動かない仮説、
payloadがsoftware ring／stashに残り続ける仮説、BUS_RESET又はquarantineで停止する仮説は否定された。
一方、Vehicleではflush successが1回成立してもCOM3は0 byteであったため、現行のdevice-side flush successは
Windows user-space CDC受信完了の証拠ではない。未解決境界は、ESP32 USB Serial/JTAG controllerがpayloadをpickupした後から、
host controller／Windows USB CDC driver／COM readerへbyteが現れる前までである。Mission Planner、MAVLink、E220 RF、
TDD、Pixhawkは今回のstandalone診断beacon 0 byteの経路外であり、直接原因ではない。

finally rollbackは両roleともattempt 1でaccepted R18 write、readback verify、再列挙をPASSした。
rollback正本は
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261011T134041417Z-027b8f12-rollback/flash_record.json)、
SHA-256 `DF803FB88FCE7C1E763E08190C2E7CF280819B836783F0A1ED8126B9B8F1861E`、final sealは
SHA-256 `12598DEF6DDC20BB8D94EEAB73FE8CB3C7FDFEAB06D3D400B75DE567DEE7A21F`である。
終了後はCOM3／COM6 `Status=OK`、残留OpenOCD／esptool／Arduino CLI process 0、TCP 3333／4444／6666 listener 0、
target halted可能性falseである。この一回限定許可は消費済みで、追加の実機操作は行わない。

本節の要約正本は
[`summary.json`](runs/validation/R19-HWCDC-FIFO-LIVE-DIAG-001/20261011T134548155Z/summary.json)である。
次はofflineで、device endpoint number／configured state／line state、IN transfer completionとhost-visible commitの相違を
test-firstで分離する。R19 acceptance／Deployment、932件30秒、Heartbeat最大2,500 msはいずれも未合格・未許可である。

### 31.22 `flushTxComplete()`最終ZLP再発行race修正（2026-10-11 JST、offline-only）

Section 31.21でGroundはpayloadを2回pickupし、`publish == pickup`、ring／stash pending 0、BUS_RESET 0、
quarantine false、final blocker noneであるにもかかわらず、flushは5回全てtimeoutし、ZLPを7回発行していた。
Vehicleもflush success 1／timeout 1が混在し、COM3は0 byteだった。コードと会計を照合し、
`flushTxComplete()`が最終ZLPを1回発行した後も、ループ末尾で`hw_cdc_flush_txfifo_if_safe()`を毎回呼ぶraceを
最有力のsoftware原因として特定した。ホストがZLPをpickupしてFIFO writableとなった後、次の完了sample前に
ループ末尾が新しいZLPを発行すると、FIFOが再びnot-writableとなり、これを繰り返してtimeoutできる。

修正は製品コード1箇所に限定した。

```cpp
if (host_present) {
  if (!final_flush_issued) {
    hw_cdc_flush_txfifo_if_safe();
  }
  hw_cdc_enable_tx_intr();
}
```

これにより、同一flush attemptのterminal ZLPを最大1回とし、pickup後の次iterationで完了を判定する。
TX割込みの再有効化は維持した。TDD、UART、E220 profile、pin、MAVLink routing、accepted R18は変更していない。

test-first検証は次の通りである。

- RED: 無条件のループ末尾reflushを`flushTxComplete can reissue its terminal ZLP...`として契約試験が検出した。
- GREEN: 決定論LL／flushモデル`UT-R19-HWCDC-LL-BOOTSTRAP-001` 44/44 PASS。
- GREEN: CMake target再buildおよび対象CTest 1/1 PASS。
- GREEN: 全host CTest 304/304 PASS、failure 0。
- GREEN: canonical及びinstalled ESP32 coreの`FW-HWCDC-TX-INTEGRITY-001` PASS。
- GREEN: HWCDC installer移行契約PASS。
- patched `HWCDC.cpp` SHA-256:
  `F62E9D139A97A760DF582870BD9FA092D7E577D4F1F947967E7F9EB114EDD71F`。

Arduino ESP32 core 3.3.11はbackup／rollback検証付きinstallerでcanonicalと同期した。その後、実機へuploadせず、
Vehicle→Ground順で製品版と診断版をcompile・seal・独立verifyし、いずれもPASSした。

製品候補は`20261011T140505553Z-18941c96`である。

- [`candidate_manifest.json`](runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/20261011T140505553Z-18941c96/candidate_manifest.json):
  SHA-256 `1DF157612CFB3D1927AFDE39E862E3A4B60528101FA123FF940E3C2F7B3474BF`
- [`final_seal.json`](runs/candidates/R19-HS-PRODUCT-CANDIDATE-BUILD-001/20261011T140505553Z-18941c96/final_seal.json):
  SHA-256 `B627B68ED55BBF0D546468D8CC4E049D27ED490D06E683120007E95F402673DD`
- Vehicle application SHA-256: `3FE92689AFB6B6DCF51EBBD6CF7968F1BDF3B7E7BDDE00BDBF8C118C89AE4EA2`
- Ground application SHA-256: `63C32244959A72E916BA08C3C4746430278A5806BCC474AAFC94020793FB87D3`

次回実機用の診断候補は`20261011T141348202Z-34b9e8b0`である。

- [`candidate_manifest.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T141348202Z-34b9e8b0/candidate_manifest.json):
  SHA-256 `2012851558FDE97861017CE90203545B5B8EB4DAE3EA5DD9A59C6E5CE519FB20`
- [`final_seal.json`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T141348202Z-34b9e8b0/final_seal.json):
  SHA-256 `709C9FBF84A58F4BE9F97DE8C6A525BA7F776E41A2D1FB8C53E9450603882B29`
- Vehicle application SHA-256: `771323BDB5ECF4A90A9E4D7F88EA4EAF1EA736B5A3C9BD8AF7B33C4166A8CCE7`
- Ground application SHA-256: `555FBC31D5BE46DE1D8BA82E67424C8AC2D1E0AE323E5375898C17406A2F67C0`

この診断候補は`runtime_fail_diagnostics_enabled=true`、`acceptance_eligible=false`、
`acceptance_authorized=false`、`deployment_authorized=false`である。追加のCOM open、JTAG、flash、upload、Mission Planner試験は
行っていない。従って修正の実機効果、932件30秒、Heartbeat最大2,500 ms、全error 0は未証明である。
次の実機操作には新たな一回限定許可と安全条件6項目の再確認が必要である。

### 31.23 final-ZLP再発行抑止後の実機評価（2026-10-11 HIL／2026-10-12解析）

一回限定許可と安全条件6項目の再確認後、Section 31.22のsealed diagnostic candidate
`20261011T141348202Z-34b9e8b0`をVehicle `COM3 / USB 1-4`、Ground `COM6 / USB 1-3`へ
application-onlyで書き込み、40秒dual-COM取得、両roleの68+96 byte record各2回読取り、finally accepted R18
rollbackを実施した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T143454467Z-8fd2c3b7/summary.json)、
SHA-256 `9A8696D1866863417A5C800042C1F3E04479883E5EDF9C84CCF4972CCFDEF610`である。
outerは`PASS / PASS_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`だが、このPASSは原因証拠取得とR18復旧を示すだけで、
R19通信の合格ではない。

40秒captureは`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`だった。

| role | raw bytes | valid frame | 内容 | 診断frame |
|---|---:|---:|---|---:|
| Vehicle／COM3 | 0 | 0 | なし | 0 |
| Ground／COM6 | 21 | 1 | MAVLink2 HEARTBEAT、msgid 0 | 0 |

Ground rawは`FD 09 00 00 A3 01 01 00 00 00 04 00 00 00 0B 03 01 05 03 F7 F1`で、capture parserは
CRC-valid、noise 0、partial 0、bad length 0と判定した。従ってR19でUSB CDCが完全に停止している仮説は否定されたが、
40秒で通常HEARTBEAT 1件だけなので、継続下り通信としては不合格である。capture summaryは
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T143454467Z-8fd2c3b7/capture/summary.json)、
SHA-256 `F25CA88330AF3FEB9399857EF832B855AEA4129A39C1FBA29CD41FB4C09ECACF`である。
runner service gapはVehicle `186,642 us`、Ground `166,494 us`で100,000 us基準を超えたため、capture timing SLAは
`NOT_PROVEN`である。これは有効な21-byte frameの存在を無効にしないが、無受信時間の厳密上限証明には使用しない。

Endpoint FIFO／runtime-stage実測は次である。

| 項目 | Vehicle | Ground |
|---|---:|---:|
| FIFO write attempt／bytes／zero | 2／63／0 | 3／84／0 |
| `WR_DONE`／raw `IN_EMPTY`／payload pickup | 14／13／2 | 17／16／3 |
| flush attempt／success／timeout／abort | 5／0／5／0 | 3／1／2／0 |
| ZLP flush | 12 | 14 |
| publish／pickup generation | 2／2 | 3／3 |
| ring／stash pending | 0／0 | 0／0 |
| BUS_RESET／quarantine／blocker | 0／false／none | 0／false／none |
| last stage | `WriteAccepted` | `FlushCompleted` |
| first failure | `FlushFailed / 0x54520010 / 4481` | `GroundBoundaryImpossible / 0x54520003 / 5884` |

両roleともrecord 2回はbyte同一で、Endpoint FIFO write、`WR_DONE`、raw `IN_EMPTY`、payload pickup、
`publish == pickup`、pending 0を再確認した。Vehicle正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T143454467Z-8fd2c3b7/stage_vehicle/summary.json)、
SHA-256 `0699EDA99243FAD2C52D70398D37AA9CB251EE5C68136E383B20F38636194CA6`、Ground正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261011T143454467Z-8fd2c3b7/stage_ground/summary.json)、
SHA-256 `04EB55959C86AB0778D0EA619B9397E7541891A5225689754A83EAD12E55CC28`である。

Section 31.22で抑止した同一attempt内のterminal ZLP再発行は実在するoffline defectだったが、今回もVehicleのflushは
5/5 timeoutし、ZLP countはVehicle 12、Ground 14だった。従って当該修正は単独では十分条件ではない。前runではVehicleだけ
flush successがあり、今回はGroundだけにflush successとhost-visible HEARTBEATがあった。この差は単一run同士なので修正の
因果効果とは断定しないが、少なくとも固定した一つのrole又は物理配線の常時停止だけでは全結果を説明できず、USB TX完了／
clean-boundary収束のliveness条件が未解決である。

`GroundBoundaryImpossible`はaggregate reasonである。現行実装は、host loss中のirreversible prefix、loss epoch変更又は
500 ms deadline、backlog／held heartbeat discard失敗、invalid local-egress pump、boundary flush失敗／epoch変更／遅延を
同じcodeへ集約する。first-failure detail `4481`／`5884`はlocal monotonic timeの下位32 bitであり、追加のerror codeではない。
Groundが`FlushCompleted`へ到達したことは「いずれかのflush成功」を示すが、first failureを生じさせた同じframeの成功を意味しない。
従って現行証拠だけで`GroundBoundaryImpossible`の個別分岐を一意に決定してはならない。

finally rollbackは両roleともattempt 1でaccepted R18 write、readback digest一致、同一identityでの再列挙をPASSした。

- Vehicle accepted R18 SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18 SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`
- rollback record SHA-256:
  `1E66AD839D1DF503E53368CFB0FF4DAF554201DA3DA51E2C733AB01D53A16431`
- rollback final seal SHA-256:
  `43BFE024409002401C520ABFAD58DA3421AAFDBE6E14945B7AE3BB24143BB515`

終了時`power_off_required=false`、JTAG cleanup／process-tree terminationは証明済みである。一回限定許可は消費済みで、
`live_flash_authorized=false`、R19 acceptance／Deploymentは未許可・未合格を維持する。932件30秒、Heartbeat最大
2,500 ms、全error 0は本runでは実施していない。

この結果のオフライン要約正本は
[`summary.json`](runs/validation/R19-HWCDC-FINAL-ZLP-LIVE-DIAG-001/20261012T-offline-summary/summary.json)である。
次は実機操作なしで、`GroundBoundaryImpossible`を個別分岐へ分解するfirst-causeラッチと、flush attempt単位の
terminal-ZLP発行／pickup／完了会計をtest-firstで追加する。機能修正を断定できる証拠はまだ不足しているため、診断分離後に
fresh candidateをcompile・seal・独立verifyし、その後にのみ別の一回限定実機許可を求める。

### 31.24 HWCDC reset-race／schema2 diagnostic trust closure（2026-10-12 JST、offline-only）

#### 範囲と実機状態

本節の作業ではCOM3／COM6、JTAG、OpenOCD、upload／flash、機器電源操作を実施していない。PC上のcanonical
ESP32 core、host test、Arduino compile、candidate builder／verifierだけを使用した。両XIAOは引き続きaccepted R18である。

- Vehicle accepted R18 SHA-256:
  `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`
- Ground accepted R18 SHA-256:
  `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`
- `live_flash_authorized=false`
- `physical_30s_proven=false`
- R19 acceptance／Deployment: **NO-GO継続**

Section 31.20～31.23の96-byte recordは当時の実機結果を表すschema 1履歴である。本節はそれらを書き換えず、次回以降に
使用するschema 2の診断信頼性を閉じる。

#### reset／publication／flush境界修正

- zero-byte FIFO write後にBUS_RESETが来ても、実際にFIFOへ書いたbyteがなければsticky quarantineを作らず、payloadをretry用に保持する。
- `IN_EMPTY` ISR entry後、payload pickup直前にBUS_RESETをTX mux内で再sampleする。late resetはpayload pickupとして数えず、
  raw-only reset-discard会計へ送る。
- bit 11 `PayloadPublishPending`はpositive FIFO writeでsetし、matching non-ZLP `WR_DONE`だけがclearする。
- bit 12 `PayloadPublishAborted`はBUS_RESET又はtask discardでsetするpersistent barrierであり、後続の非payload eventでは消えない。
  次のpositive FIFO publicationだけがclearする。
- bit 13 `PayloadFlushPending`はpositive FIFO writeでsetし、同じ新規publicationが全てpickupされた後のclean flush successだけが
  clearする。過去世代のflush成功を新payloadへ再利用できない。
- `PayloadInFlight => PayloadFlushPending`を必須とし、違反するstable snapshotを無効化する。
- outerはrecord flagsのbits 2～9とdecoded booleanを独立照合し、不一致をfail-closedにする。

診断macro ONの最初のfresh candidate buildでは、`HWCDC::begin()`内の`goto err`が後置された
`diagnostic_record_ready`初期化をまたぐC++違反を検出した。赤証拠は
[`BUILD_FAILED.txt`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261011T212401280Z-1eb9b511/BUILD_FAILED.txt)
である。変数宣言を関数冒頭かつ最初の`goto`より前へ移すだけの最小修正を行い、TDD、UART、MAVLink、CDCの実行順序は
変更していない。修正後HWCDC.cpp SHA-256は
`6CB63D54E63A4C0511878AAFDE8B914819E6C23BDD2D1F8852E5C1530DFF25B5`である。

#### 現行診断ABI

| 項目 | 現行値 |
|---|---:|
| Endpoint FIFO schema | 2 |
| Endpoint FIFO words／bytes | 28／112 |
| runtime-stage bytes | 68 |
| reader schema | `vc-lora-r19-runtime-stage-jtag-read-v3` |
| known flag mask | `0x00003FFF` |
| terminal blocker mask | `0x000000FF` |

reader-v3はCPU halt中に68-byte runtime-stageと112-byte Endpoint FIFO recordを各2回読み、symbol、size、sequence、generation、
known mask、counter、address非重複、last-event BUS_RESET、publish pending／aborted、flush pendingを判定する。outerはreaderの
evidence proofとcompletion proofを別々に要求し、`usb-tx-boundary-complete`以外を成功扱いしない。

#### オフライン検証結果

| 検証 | 結果 |
|---|---:|
| diagnostic record host unit | 153/153 PASS |
| LL bootstrap／reset-race model | 59/59 PASS |
| product-source contract | 45/45 PASS |
| runtime diagnostic unit | 203/203 PASS |
| HWCDC semantic contract | 61/61 PASS |
| reader contract | 113/113 PASS |
| outer／installer／candidate builder／pin cascade | PASS |
| fresh Clang 22.1.8 build | 115/115 PASS |
| fresh CTest | 304/304 PASS、FAIL 0 |
| internal aggregation | 275 PASS、expected XFAIL 2、FAIL 0 |
| normal Arduino compile | Vehicle→Ground PASS |
| diagnostic Arduino compile／candidate seal／independent verify | Vehicle→Ground PASS |

fresh host logは
[`full_host_suite.log`](runs/validation/R19-HWCDC-DIAGNOSTIC-TRUST-CLOSURE-OFFLINE-001/20261012T065057148+0900/full_host_suite.log)、
SHA-256 `07F1BB5142853E77483AF63848378DE691073755E2EBF2ACC6A7676C7F9616EB`である。CTest `LastTest.log`の
SHA-256は`286B459E83851B174F1653B466347D30792AC8E3560A2BD7BB2EB726DC64609F`である。

通常版compile manifestは
[`firmware_manifest.json`](runs/phase6_arduino_compile/firmware_manifest.json)、SHA-256
`53D43F5420514255D797A9CE26CFAFDF76D285A16296FD35E1EE65C40C3D37C1`である。

#### fresh schema2診断候補

診断候補`20261011T213059634Z-4a5ff626`をVehicle→Ground順でcompileし、builderと独立verifierの両方がPASSした。

| 成果物 | SHA-256 |
|---|---|
| Vehicle application | `7FC6BEF40C9E8B24DFC1485E8947BB797B3AFE74C6EB137E4C14E263181C6753` |
| Ground application | `FEA0009DAC0C7C8D3EB3D8CA4FE8769B6E6F3BAA01505F1F78FEA3F6B32CFFC1` |
| candidate manifest | `8002C6F7ED974EEEFDC1188386A5DB9DFB139EE22DD44A9D700659F9391ECF54` |
| handoff | `06B59163623C526F9A8ED86F1AFA8DD9EC89CEF2EBD66D4F2920CD729A258D83` |
| final seal | `44189748E4FE7CE0C28B4B67729A062D855053087E9A12B79461A6C93D15AB76` |
| latest pointer | `6FB6D7D02FAB0964FC914C61FFBA0751123B77FE98D21588D2C8603775C9881E` |

候補は`runtime_fail_diagnostics_enabled=true`、`acceptance_eligible=false`、`acceptance_authorized=false`、
`deployment_authorized=false`である。これは診断専用であり、生成済みであること自体は書込み許可を意味しない。旧候補
`20261011T141348202Z-34b9e8b0`はschema 1の履歴であり、現行gateの必須schema 2 ABI fieldを持たないため再書込み対象外である。

必須semantic集合は34件（diagnostic 30件＋critical all-build 4件）、obsolete pin hitは0件である。成果物はtrusted local
repo／toolchain下ではseal済みである。一方、敵対的artifact／toolchainに対するchecker executable自身の独立allowlistと完全な
TOCTOU耐性は未証明であり、P2 hardening残件とする。

#### 次段階

本節は「R19 live CDCが修復された」とは主張しない。次の実機診断には、新しい一回限定許可と安全条件6項目確認が必要である。
accepted R18上のactive-JTAG pre-flash gateがPASSした場合だけ本節のfresh schema2候補を書き込み、40秒dual-COM、両roleの
68+112 byte record各2回、必須rollbackを実施する。診断bootstrap成立後、別許可で932/932、30,000 ms、Heartbeat最大
2,500 ms、全error 0を同時評価する。

### 31.25 schema 2 Endpoint FIFO実機診断とempty-ISR ZLP chase特定（2026-10-12 JST、HIL）

一回限定許可と安全条件6項目の再確認後、Section 31.24の診断候補
`20261011T213059634Z-4a5ff626`についてfresh dual active-JTAG preflightをPASSさせ、application-onlyで両roleへ書き込んだ。
その後、40秒dual-COM取得、runtime-stage 68 byte及びschema 2 Endpoint FIFO 112 byte recordの各2回読取り、
finally accepted R18 rollbackを実施した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T013529921Z-765dcede/summary.json)、
SHA-256 `067E5BB6A3E816FE31EB212F52304F846C708E124BC59E635FE654A34670A92D`である。
結果は`FAIL / FAIL_STAGE_READ_R18_RESTORED`である。このstatus名にかかわらず、両roleのstage record読取り自体はPASSし、
失敗理由はUSB TX boundary completion未成立である。

40秒captureは`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`で、COM3／COM6とも0 byteだった。両portはopen済みであり、
serial writeは行っていない。parser errorは0だが、入力0 byteなのでlink healthの合格証拠にはしない。capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T013529921Z-765dcede/capture/summary.json)、
SHA-256 `F281DB645DFCBA50AAB2CC1F7187A6232E998991B4BB71608D38E9E6F537FB0C`である。runner最大service gapは
Vehicle `48,561 us`、Ground `39,883 us`だった。

両roleのrecordは2回の読取りでbyte同一で、stage mask `0x00003FFF`、last stage `WriteAccepted`、first failure
`FlushFailed / 0x54520010`だった。record flagsはlast-committed diagnostic eventであり、連続的なlive hardware stateではない。
主要会計は次の通りである。

| 項目 | Vehicle | Ground |
|---|---:|---:|
| FIFO write attempt／bytes／zero | 2／63／0 | 2／63／0 |
| `WR_DONE`／raw `IN_EMPTY`／payload pickup | 7／6／2 | 8／7／2 |
| flush attempt／success／timeout | 5／0／5 | 5／0／5 |
| ZLP flush | 5 | 6 |
| publish／pickup generation | 2／2 | 2／2 |
| ring／stash pending | 0／0 | 0／0 |
| BUS_RESET／quarantine | 0／false | 0／false |
| final blocker | `FifoNotWritable (0x8)` | `FifoNotWritable (0x8)` |
| flags | `0x00002007` | `0x00002007` |

Vehicle正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T013529921Z-765dcede/stage_vehicle/summary.json)、
SHA-256 `5ED952DB7E65D73660542E2A53B31F8499AA14B68A05332169768E2A57EB2B45`、Ground正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T013529921Z-765dcede/stage_ground/summary.json)、
SHA-256 `430D68362D9B1EA13110A4020C9496234ECFAADBE99864B4DCC3EB22818B2FD6`である。

`publish == pickup == 2`、pending 0、BUS_RESET 0なので、63 byte payloadは32+31 byteとしてFIFOへ正常投入され、
host pickupまで完了している。残る会計は次の通りである。

```text
Vehicle: 非payload IN_EMPTY = 6 - 2 = 4、ZLP = 5 = 回収4 + 未回収1
Ground : 非payload IN_EMPTY = 7 - 2 = 5、ZLP = 6 = 回収5 + 未回収1
```

すなわち空キュー`IN_EMPTY` callbackが、直前にhostへ回収されたZLPの代わりに新しいZLPを発行し、常に1個をFIFOへ
残していた。これが全flush attemptを`FifoNotWritable`のままtimeoutさせる自己持続loopであり、今回観測した0 byte停止の
共通原因である。全payload FIFO writeは32 byte以下、USB endpointは64 byteで、最後の31 byteは既にshort packetであるため、
空キューISRからの追加ZLPは不要である。この証拠は共通USB CDC completion defectを特定するが、RF／TDD経路全体の独立合格を
主張するものではない。

finally rollbackは両roleともattempt 1でaccepted R18 write、readback、再列挙をPASSした。accepted R18 SHA-256はVehicle
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。rollback
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261012T013531452Z-f209304f-rollback/flash_record.json)
のSHA-256は`DF4B639E9571B2D640131C4DE4DEA8F359DB3F84C54864AD8469DF7711E0338E`、
`final_seal.json`は`3F2B58E75562479AFE1344B5754880DFF6841BD4C9EE0E9418B740AD1CF6A7F1`である。
終了時`power_off_required=false`で、両XIAOはaccepted R18、追加実機許可なしの状態へ戻った。この一回限定許可は消費済みである。

### 31.26 empty-queue IN_EMPTY replacement ZLP抑止（2026-10-12 JST、offline-only）

Section 31.25の実測原因に対し、失敗試験を先に固定してから製品コードを最小修正した。Section 31.22がtask loop内の
terminal ZLP再発行を抑止したのに対し、本節は空キュー`IN_EMPTY` callbackのreplacement ZLP chainを抑止する。
空キュー分岐から`record_zlp_wr_done()`及び`usb_serial_jtag_ll_txfifo_flush()`を除去し、割込みdisable、
ring／stash再確認、producer race時の条件付きrearmは維持した。`flushTxComplete()`のtask側one-shot terminal ZLP、
payload WR_DONE、cold-start kickは維持している。TDD、UART、E220 profile、pin、MAVLink routing、通信速度は変更していない。
本節ではCOM、JTAG、OpenOCD、flash、upload又は機器電源操作を行っておらず、両XIAOはaccepted R18のままである。

test-first証拠は次の通りである。

- RED: 旧`HWCDC.cpp` SHA-256 `6CB63D54E63A4C0511878AAFDE8B914819E6C23BDD2D1F8852E5C1530DFF25B5`を、
  空キューISRがZLP／FIFO flushを行わない新契約で検査し、期待通りFAILした。
  [`summary.json`](runs/validation/R19-HWCDC-ISR-ZLP-LIVENESS-OFFLINE-001/20261012T020000000Z-red/summary.json)、
  SHA-256 `B47FEE606FA2569CB4C39F9127EF4CA19843DA20DD8F0F32F570774B9706DE43`。
- GREEN: 修正後`HWCDC.cpp` SHA-256
  `5CF1835AE4DE0CD1CB2C3DE6AD0B8E25336690863A4E28354A9EBA8D4D8448F9`で同契約PASS、installed／canonical一致。
  [`summary.json`](runs/validation/R19-HWCDC-ISR-ZLP-LIVENESS-OFFLINE-001/20261012T021500000Z-green/summary.json)、
  SHA-256 `4DFA6FE8BCCA3E59D5CD29C2BD2DC38D9713F4381C9FD9FA807E21DB90088691`。
- installerは旧schema 2三ファイル組の正確なhashだけを`prior-canonical`として移行し、header欠落又は混在generationを拒否する。
- fresh host buildは115/115、CTest 304/304 PASS、internal aggregation 275 PASS／expected XFAIL 2／FAIL 0。
- LL bootstrap／reset-race model 59/59、product-source 45/45、FIFO diagnostic 153/153 PASS。

最初のhost test実行は、不完全な`llvm-mingw-20260616-tar` fallbackに標準header `<regex>`が欠落して停止した。
同じ`clang++.exe`を持つcomplete toolchainではdirect probe及び全試験がPASSしたため、これは
`ENVIRONMENT_TOOLCHAIN_INCOMPLETE`として扱い、製品failureへ数えない。headerを単独copyして異なるtoolchain rootを混在させてはいない。

通常Arduino版はVehicle→Ground順にcompileし、manifest verifyをPASSした。

| 成果物 | 結果／SHA-256 |
|---|---|
| 通常compile manifest | `B59D7AE9F486C706A80BD479ED48E151B72126BCCB4C7012A2EE8C17A53AB09B` |
| 通常source tree | `600A8E8744479D8193A693B21FA8B82F500DBCDCE19833DE1548E925E7DEADCD` |
| Vehicle通常application | `C4847BAE7841642A629395B9E5A26107A7E2AF7EEAA5EA55A57F55252CE8643F` |
| Ground通常application | `22F1A84E7C8A5F94BD38622A9BB03AA4698D632749E5FE88CBC803FA69EB86AC` |

これらはbuild済み成果物であり、accepted又はdeployedを意味しない。修正後のfresh schema 2診断候補は
`20261012T021645260Z-8cca63e5`で、builder、seal、独立verifierをPASSした。

| 成果物 | SHA-256 |
|---|---|
| Vehicle diagnostic application | `089694EA07C724B7C7AF3C13ABBDC1E1F2162999363BC01144DA3101055B41E6` |
| Ground diagnostic application | `846238FB7BFC29A169092157BEEE4AA9DD7E9640AAF90DD02C1F0A3D626D61CB` |
| candidate manifest | `D55D4A76319CBB85AF66CE3CF6271C6074C725479A18B1773922666D94FAEA6A` |
| handoff | `88520CBFFB6F6928D7F00AF6DF33695FAF3AEA1F113CF5E99923C37B066CD23B` |
| final seal | `DC747ACD9643CBB7AF3DC07309FE40773167779B8868BEC9D02E777B687489C0` |
| latest pointer | `2FA5A80903684ACB8CE36F61BE128E259126C36D910F10B6C01CA42CAA45060A` |

候補は`runtime_fail_diagnostics_enabled=true`、`acceptance_eligible=false`、`acceptance_authorized=false`、
`deployment_authorized=false`である。オフライン要約正本は
[`summary.json`](runs/validation/R19-HWCDC-EMPTY-ISR-ZLP-LIVENESS-OFFLINE-001/20261012T113017642+0900/summary.json)、
差分は同directoryの`changes.patch`である。

本節は原因修正のオフライン妥当性を証明するが、実機修復の証明ではない。両XIAOはaccepted R18のままで、
R19 acceptance／Deploymentは**NO-GO継続**である。932/932を30秒以内、Heartbeat最大2,500 ms、全error／parser異常0は
修正後に未評価である。次の実機診断には新たな一回限定許可と安全条件6項目確認が必要である。accepted R18上の
active-JTAG preflightを先にPASSさせた場合のみfresh candidateを書き込み、40秒dual-COM、両role record各2回、
必須R18 rollbackを行う。その結果でCOM3／COM6非0 byte及びZLP会計の収束を確認した後、別許可で最終受入を実施する。

### 31.27 active-JTAG USB location bindingのfail-closed停止（2026-10-12 JST、HIL・書込み前停止）

一回限定許可と安全条件6項目の再確認後、Section 31.26のfresh schema 2診断候補
`20261012T021645260Z-8cca63e5`を対象に実機診断outerを起動した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T071351900Z-d45474b4/summary.json)、
SHA-256 `D2E16B6A713DCA304C0A50EC9FF1E128269AA5B8ADB6BB2EDF2664CCBE0B9B82`である。結果は
`FAIL / FAIL_ACTIVE_JTAG_LOCATION_BINDING_NO_FLASH`であり、明示指定したOpenOCD USB locationがfresh PnP port chainと
一致しないため、active-JTAG及びfirmware書込みの前にfail-closedで停止した。

PnP／WinUSB確認自体は両roleでPASSしている。現在の物理割当はVehicle COM3（serial `90:70:69:11:81:A4`、port chain `3`）と
Ground COM6（serial `1C:DB:D4:5A:83:80`、port chain `4`）である。今回指定した旧値Vehicle `1-4.4`／Ground `1-4.2`は、
再接続後のfresh topologyと不一致だった。次回の明示値はVehicle `1-3`、Ground `1-4`とする。この結果はUSB-JTAGドライバー、
COM CDC、配線又はR19 firmwareの故障を示すものではなく、host invocationと現在のUSB topologyのbinding不一致を示す。

実行されたstepはPnP中心の`jtag_preflight`だけで、`active_jtag_preflight`、candidate install、40秒dual-COM capture、
runtime-stage 68 byte／Endpoint FIFO 112 byte read、rollbackは未実行である。firmware-mutating hardware interactionはなく、
診断候補は書き込まれていないため、両XIAOはaccepted R18のままである。終了時COM3／COM6は存在し、
`power_off_required=false`である。本一回限定許可は起動時に消費済みで、同許可による自動再試行は行わない。

したがってSection 31.26のUSB CDC修正が実機で0 byte停止を解消したかは未評価であり、R19 acceptance／Deploymentは
**NO-GO継続**である。次回は新たな一回限定許可と安全条件6項目再確認後、fresh PnP値を再確認し、Vehicle `1-3`／
Ground `1-4`が一致する場合だけ同一候補で診断を再実行する。locationが再び変化していた場合は書込み前停止を維持し、
そのfresh値へ明示的に更新する。

### 31.28 empty-ISR ZLP抑止後の実機再診断とpre-capture fail-stop分離（2026-10-12 JST、HIL）

新しい一回限定許可と安全条件6項目の再確認後、fresh PnP topologyを再取得し、Vehicle COM3／serial
`90:70:69:11:81:A4`／OpenOCD USB location `1-3`、Ground COM6／serial `1C:DB:D4:5A:83:80`／
OpenOCD USB location `1-4`の一致を確認した。両roleのactive-JTAG preflightをPASSさせた場合だけ、Section 31.26の
診断候補`20261012T021645260Z-8cca63e5`をapplication-onlyで書き込み、40秒dual-COM取得、runtime-stage 68 byte及び
schema 2 Endpoint FIFO 112 byte recordの各2回読取り、finally accepted R18 rollbackを実施した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T074933411Z-cd4a834c/summary.json)、
SHA-256 `662A71E4CA6B994C855E93297EE2B3F194CFA9F100C96AA131B63D9CA83F4673`である。結果は
`FAIL / FAIL_STAGE_READ_R18_RESTORED`で、active-JTAG、install、両role record読取り及びrollbackはPASSし、captureだけが
`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`だった。

40秒captureではCOM3／COM6とも0 byte、frame 0、serial write 0、parser error 0だった。入力0 byteなのでparser error 0を
通信合格証拠にはしない。runner最大service gapはVehicle `41,121 us`、Ground `39,375 us`であり、runner停止による0 byteでは
ない。capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T074933411Z-cd4a834c/capture/summary.json)、
SHA-256 `981D04B7E079B73584E9B70EE21F962F56E9AC93A84F3A643064CCB9AA3E8BA1`である。

両roleのruntime-stage及びEndpoint FIFO recordは各2回の読取りでbyte同一だった。修正前Section 31.25との主要比較は次の通りである。

| 項目 | 修正前 Vehicle／Ground | 修正後 Vehicle／Ground |
|---|---:|---:|
| COM取得 | 0／0 byte | 0／0 byte |
| runtime stage | `0x3fff`／`WriteAccepted` | `0x7fff`／`FlushCompleted` |
| FIFO write attempt／bytes／zero | `2/63/0`、`2/63/0` | `4/126/0`、`3/84/0` |
| publish／pickup generation | `2/2`、`2/2` | `4/4`、`3/3` |
| flush attempt／success／timeout | `5/0/5`、`5/0/5` | `2/1/1`、`3/1/2` |
| ZLP flush | 5、6 | 3、3 |
| last ISR ZLP | schema 2旧記録 | 0、0 |
| final blocker | `FifoNotWritable` | `SoftwarePending + FifoNotWritable` |
| USB TX boundary完了証明 | false／false | false／false |

修正後Vehicleでは`WR_DONE / IN_EMPTY / payload pickup = 7/8/4`、Groundでは`6/7/3`である。したがって非payload
`IN_EMPTY`は両roleとも4回で、ZLP累計3回を上回る。修正前の`ZLP = 非payload IN_EMPTY + 未回収1`という自己持続会計は消え、
両roleでflush successが1回ずつ成立した。`last_flush_isr_zlp_count=0`でもある。従ってSection 31.26のempty-queue ISR
replacement-ZLP抑止は、意図した層で有効だった。一方、最終flushは両roleともtimeoutし、`PayloadFlushPending=true`、
USB TX boundary completionはfalseである。Vehicle first failureは`FlushFailed / 0x54520010 / 2161`、Groundは
`GroundBoundaryFlushFailed / 0x5452001c / 5423`だった。Vehicle正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T074933411Z-cd4a834c/stage_vehicle/summary.json)、
SHA-256 `276FC8CD651D56DE3F76E76A49D084271555C46BD1DAE7D3F4168132F87348D0`、Ground正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T074933411Z-cd4a834c/stage_ground/summary.json)、
SHA-256 `694D8C3F49CC1F6C7793F11EDEE1C220B97412E7E96202FE204129A267D756C9`である。

ただし、この0 byte captureを「修正後製品経路でもWindows CDCへ1 byteも到達しない」という証拠にはしない。候補はboot直後から
診断送信を開始し、最初のtransport failureで`r19_runtime_fail_diagnostic_transport_failed=true`をlatchedすると、その後の
`r19_service_runtime_fail_diagnostic()`を永久停止する。installは両roleへ逐次実行され、Vehicleは`07:50:32.599Z`、Groundは
`07:50:45.517Z`に再列挙したのに対し、capture openは`07:50:48.611Z`だった。Vehicleのfailure detail `2161 ms`はcapture開始の
約14秒前、Groundの`5423 ms`もcapture開始付近までに発生し得る。このため、一度は成立したflushと送信byteがCOM handle open前に
消費され、その後は診断側fail-stopによって新規frameが生成されなかった可能性が高い。Endpoint FIFO recordはdevice側のwrite／
pickupを証明するが、Windows user-space COM handleの受信は証明しない。本runは、古いISR ZLP loopの解消を証明する一方、
post-fix製品CDCのend-to-end livenessを合否判定できない診断開始条件だった。

次のオフライン修正では、TDD、E220、UART、MAVLink又は通信速度へ触れず、診断専用経路をtest-firstで次の順に修正する。

1. software pending中にtask側maintenance ZLPを発行しない回帰試験を追加し、terminal predicate所有のone-shot ZLPだけを残す。
2. capture readerが成立する前の一時的100 ms timeoutを永久fail-stopへ変換しないhost-ready／再試行契約を追加する。
3. 診断stream開始後にCOM3／COM6非0 byteを確認してから、別の一回限定許可で実機再診断する。

finally rollbackは両roleともattempt 1でwrite、readback、再列挙をPASSした。rollback
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261012T074934971Z-922f3fac-rollback/flash_record.json)
のSHA-256は`F6B4A2E39FABB78C644E1E139209C5FFA202A0C401EDE34BFD44A860313EB691`、`final_seal.json`は
`4E4BA3DFC773A6CB74E1F4FC03360582E16A029D071D68E76B1D92E5D4E20E2D`である。accepted R18 SHA-256はVehicle
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`と再計算値が一致した。終了時はCOM3／COM6が存在し、
cleanup及び両CPU runningを確認し、`power_off_required=false`である。両XIAOはaccepted R18へ復旧済みで、本一回限定許可は
消費済みである。

R19 acceptance／Deploymentは**NO-GO継続**である。932/932を30秒以内、Heartbeat最大2,500 ms、全error／parser異常0の
同時条件は本runで未評価であり、診断経路を修正して非0 byteを証明するまでは最終受入へ進めない。

### 31.29 terminal-ZLP cross-call所有権とstale ISR snapshot排除（2026-10-12 JST、offline-only）

Section 31.28で残った`PayloadFlushPending`及びcapture前永久停止に対し、失敗試験を先に固定してからUSB CDC完了条件を
修正した。`flushTxComplete()`のterminal ZLP所有権をcall-local boolから`None / InFlight / PickedUp`の永続状態へ変更し、
`tx_loss_epoch`、payload publish generation、payload pickup generationへ結び付けた。同一generationのretryは既存ZLPを
引き継ぎ、新しいZLPを再発行しない。新しいpayload publish、reset／discard、begin／end及びclean completionでは所有権を
無効化する。terminal ZLPはTX mux内でIN_EMPTYをmask、stale statusをclear、所有権をbind、`WR_DONE`、re-enableの順に
発行する。ISRはentry snapshotを信用せず、同じmux取得後にBUS_RESET／IN_EMPTYを再取得するため、古いISR entryが新しい
terminal ZLPを誤回収できない。診断には厳密な`record_flush_retry_attempt()`を追加したが、Endpoint FIFO recordは
112 byte schema 2を維持した。TDD、UART、E220 profile、pin、MAVLink routing及び通信速度は変更していない。

test-firstでは旧実装に対し、同一generationのflush re-entryがterminal ZLPを再発行するREDと、retry診断API欠落のREDを
確認した。修正後はLL model 67/67、Endpoint FIFO record 160/160、product-source contract 45/45をPASSした。
product-source contractは単なる文字列緩和ではなく、IN_EMPTY branch内のmux取得後live sample、同じsampleからの
BUS_RESET／IN_EMPTY導出、reset-discard helper内のpre-clear raw witness、combined clear及びJTAG record保存順を局所的に
検査するよう強化した。fresh host buildのCTestは304/304 PASS、internal aggregationは275 PASS／expected XFAIL 2／FAIL 0で、
[`runs/summary.json`](runs/summary.json)のSHA-256は
`CC79D7D1366BBEBDEE2C151FB734AC352384F2C6CB0C574670B02701FA31AA81`である。途中、不完全な
`llvm-mingw-20260616-tar` fallbackが標準header `<regex>`欠落で停止したが、complete toolchainで全304件がPASSしたため、
これは`ENVIRONMENT_TOOLCHAIN_INCOMPLETE`であり製品failureではない。

canonical／installed ESP32 coreの主要SHA-256は次の通りである。

| ファイル | SHA-256 |
|---|---|
| `HWCDC.cpp` | `CEF895A3CD6B649FF874649BF9118ADC8C40E774764D0DD8696DE531FAAA8D12` |
| `HWCDC.h` | `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC` |
| `HWCDCR19Diagnostic.h` | `4D10BF94D20DB0E864A3484FC005884C80CC809B6408DF37B3A603AEC461A1CF` |

全host試験後に通常Arduino版をVehicle→Ground順で再compileし、manifest verifyをPASSした。通常manifest SHA-256は
`EA291D058BE16D4A28980B7B0D6855A459FF8B4C6A76BB905D192BF623C4AF27`、source treeは
`3A9BFBFAE72F034E19C789E646162C335CFEDA8CFD7329F5CF70509C28336D38`、Vehicle applicationは
`C84A19BA97A47B8E589E35D09076196A665267AD6A59F8E46410EA8B9293CF5C`、Ground applicationは
`A2EE2BD38DFF99833705B8DF53EFAAF0654DFEF8152AA8912FEB1FEB322D95C1`である。

修正後のfresh診断候補は`20261012T100247548Z-75f509c1`で、builder、seal及び独立verifierをPASSした。

| 成果物 | SHA-256 |
|---|---|
| Vehicle diagnostic application | `9D009B00CE665EC8CAF2DD182C5FF2E4753238DF57B58E24BB24E593170E8EE8` |
| Ground diagnostic application | `6295571899A284E8BBA54D8480CF580D498AEEAAF8B99AB51F1547963D67CDA5` |
| candidate manifest | `EBEBE18DFA5853DD44D175476DFEE3D24249A2E199A195A5C08F8122F1ED94BC` |
| handoff | `2197A0A1F9BD564FC17D8728E6EA9327D1741959B69CF71B00FC381175BBB614` |
| final seal | `44719795EBC39BB547A711A56445C9331FF0FADE092AC91E3C8371EE9008E1B5` |
| latest pointer | `68E0903389E2561C1ACFB3D089F905E341FC56805D50554813204A7F38F5F637` |

候補は`runtime_fail_diagnostics_enabled=true`、`acceptance_eligible=false`、`acceptance_authorized=false`、
`deployment_authorized=false`である。オフライン正本は
[`summary.json`](runs/validation/R19-HWCDC-TERMINAL-ZLP-OWNERSHIP-OFFLINE-001/20261012T192316237+0900/summary.json)、
SHA-256 `612F341D491FC4FB964561FE4473BDA768E4F4B7A654116940CA435C9C733DF5`、差分記録は同directoryの
`changes.patch`、SHA-256 `73EF7E72E8E0A0CB0F2F31029274853E61BFBC420EEF1C59493CD6B5EA5D8E63`である。

本節ではCOM、JTAG、OpenOCD、flash、upload又は機器電源操作を行っておらず、両XIAOはaccepted R18のままである。
ユーザーから新しい一回限定許可と安全条件6項目再確認は受領済みだが、live outer未起動のため許可は未消費である。
次はtool-only及びPnP-only preflightでfresh COM／JTAG topologyを確認し、PASSした場合だけこのsealed candidateを対象に
一回の診断outerを起動する。outerはapplication-only書込み、40秒dual-COM、両role 68+112 byte record各2回及びfinally
accepted R18 rollbackを実施する。R19 acceptance／Deploymentは**NO-GO継続**であり、COM3／COM6非0 byte確認後も、
別の受入許可で932/932を30秒以内、Heartbeat最大2,500 ms、全error／parser異常0を同時達成するまで合格としない。

### 31.30 short-packet terminal ZLPとGround task-prime欠落の実機分離（2026-10-12 JST、HIL）

Section 31.29の診断候補を一回限定で実機評価したouter正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T102934288Z-4ac69fd4/summary.json)、
SHA-256 `916BEB693C66A137FDE964869FA5FDF685FC9F7EE3AF263438071ADFED11FF03`である。結果は
`FAIL / FAIL_STAGE_READ_R18_RESTORED`だった。40秒dual-COMはVehicle COM3、Ground COM6とも0 byte、serial write 0であり、
入力0 byteのためparser error 0を通信PASSには使用しない。capture正本SHA-256は
`B8E3FAF2611D352166CA7AED4CEAE4DBD7691D989C19FAE5B53165EB66F8E160`である。一方、両roleの68-byte runtime-stage及び
112-byte Endpoint FIFO recordは各2回同一で読取りPASSした。

| 証拠 | Vehicle | Ground |
|---|---:|---:|
| FIFO attempt／bytes／zero | `2 / 63 / 0` | `2 / 63 / 0` |
| 最終FIFO write | 31 byte | 31 byte |
| publish／pickup generation | `2 / 2` | `2 / 2` |
| ring／stash pending | `0 / 0` | `21 / 0` |
| last task／ISR ZLP | `1 / 0` | `0 / 0` |
| flush attempt／success／timeout | `5 / 0 / 5` | `7 / 1 / 6` |
| 最終blocker | `FifoNotWritable` | `SoftwarePending` |

Vehicle record正本SHA-256は`F46CFDAC9861456D8EA7BB12BCC94EA23764ECD21FE90E61AD027C53255DC0AA`、Groundは
`814C538EFE0DCA26E1DBA2698A6A9542CF9DE184AFA25900BF8564FC0E569E7D`である。

Vehicleは63 byteを32+31 byteでendpointへ発行し、両payloadのpickupまで完了していた。USB bulk/CDCでは31 byteは64-byte
endpointに対するshort packetであり、その時点でtransfer境界を表す。従って追加terminal ZLPは不要である。旧実装はそれでも
ZLPを要求し、payload 0 byte、publish=pickup、ring/stash 0にもかかわらず`FifoNotWritable`で完了を待ち続けた。

Groundも最初の63 byteは全てpickupしたが、その後に積まれた21 byteがringへ残った。enqueue前がclean-idleで、古い
`IN_EMPTY`処理が終わった後に新payloadを追加した場合、新しいedgeだけを待つ旧処理ではendpoint送信を再始動できない。
従ってGroundの直接原因は、clean-idle enqueue後のtask-side payload prime欠落である。

この二つはR19で追加したUSB CDC完了／再起動処理の別々のliveness defectである。本runはMission Planner protocol、MAVLink frame、
E220 RF、TDD schedule、UART速度、配線又は電源を原因とする証拠を示していない。rollback正本は
[`20261012T102934607Z-3d24be91-rollback`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261012T102934607Z-3d24be91-rollback/)
で、`flash_record.json` SHA-256は`84E9823CCC3A2D05641243689DEC0EF27BC77F0AD3FC0B7DFE9170F88048D55C`、
`final_seal.json`は`51C1B9CEB2F3CBDCD9C09288B1241927A60BDED0AA95511E0A68DD56B28E93F7`である。両XIAOは
accepted R18へ復旧済みで、一回限定許可は消費済みである。

### 31.31 short-packet完了とclean-idle task-prime修正（2026-10-12 JST、offline-only）

Section 31.30の二つの実機原因に対し、失敗試験を先に追加してからR19診断macro内だけを修正した。USB endpoint packet sizeを
64 byte、1回のpayload publication上限を32 byteとして明示し、最終write sizeが既知の1..63 byteならterminal ZLPなしで
完了する。64 byte又はsize不明の将来経路では従来の厳密なone-shot terminal-ZLP所有権を維持する。JTAG readerも、既知の
short packetとZLP 0の組合せだけを`success-with-short-packet-no-zlp`に分類し、size不明、full packet又は会計矛盾はfail-closedとする。

Ground側はenqueue直前が厳密なclean-idleの場合だけ既存producer fenceを取得し、stale `IN_EMPTY`をmask／clearした後、task側から
最大32 byteをFIFOへ直接primeする。zero writeではpayloadを保持し、partial writeでは未書込みsuffixをring先頭へ戻す。
BUS_RESETをpublication前後で再取得し、resetと競合したwriteを成功扱いしない。write後に遅れて観測したresetはsticky quarantine
handoffへ残し、次のclean resetまで別ISRが解除できない。通常R18 macro-off分岐は旧処理を維持する。TDD、UART、E220 profile、
pin mapping、MAVLink routing及び通信速度は変更していない。

test-first REDは次である。

- LL model: short packet後に不要ZLPを発行する2件
- task-prime model／source: clean-idle 21 byteを直接FIFOへ進められない4件
- FIFO診断: short-packet成功API欠落
- installer契約: Section 31.29でcanonicalだった`CEF895A3... / 1901C4C1... / 4D10BF94...`の三つ組をpriorとして認識できない1件

修正後のオフライン結果は次である。

| 検証 | 結果 |
|---|---|
| focused CTest | 4/4 PASS |
| HWCDC厳密契約 | PASS、canonical `HWCDC.cpp=648DC44B...255D` |
| installer契約 | PASS、exact 3-file migration／unknown・mixed拒否／強制失敗rollback確認 |
| JTAG reader契約 | 115/115 PASS、hardware interactionなし |
| 全host CTest | 305/305 PASS、完全版Clang 22.1.8 |
| internal aggregation | 275 PASS／expected XFAIL 2／unexpected FAIL 0 |
| 通常Arduino | Vehicle→Ground PASS、manifest verify PASS、flashなし |
| R19診断候補 | Vehicle→Ground build、seal、独立verify PASS、flashなし |

デフォルト探索で選ばれた不完全な`llvm-mingw-20260616-tar`は標準header `<regex>`欠落によりtest開始前に停止した。完全版
`llvm-mingw-20260616-complete`を明示指定すると全305件がPASSしたため、この停止は`ENVIRONMENT_TOOLCHAIN_INCOMPLETE`であり、
製品failureとは分類しない。

PC上Arduino coreは、Section 31.29、旧compile manifest、候補`20261012T100247548Z-75f509c1`及びHIL入力manifestが同一正本として
記録する直前tupleから移行した。installerは次の3ファイル**完全一致**だけをprior canonicalとして認識する。diagnostic header欠落又は
別世代混在は引き続き`unknown-or-mixed`で拒否する。移行後の`-CheckOnly`はcurrent canonical完全一致でPASSした。

| ファイル | 移行前 | 移行後current canonical |
|---|---|---|
| `HWCDC.cpp` | `CEF895A3CD6B649FF874649BF9118ADC8C40E774764D0DD8696DE531FAAA8D12` | `648DC44BEED5525890E728AC5215828B8CBE81E3C1C80E71FDD0D77935DC255D` |
| `HWCDC.h` | `1901C4C1CF17884AAB2B6F8ECE909E2117E9893C0FF6F579F7562E4015415BCC` | 同左 |
| `HWCDCR19Diagnostic.h` | `4D10BF94D20DB0E864A3484FC005884C80CC809B6408DF37B3A603AEC461A1CF` | `DE55AE69EF22D6EE6F8B4C01F4AF25663B62262E9C66D8BEDAB7C4033A262F60` |

通常Arduino manifest SHA-256は`939EF4B4CB1B27CFB0FA711C7D0D10588F9AE839E79D735BE64B1B1233CA2B2E`、source treeは
`0611C3C034D5E422415CABAFDB342FD710042A129EBC46707741177D5E49AC65`、Vehicle applicationは
`307DFEFAEAC5F915B7C957477C13CDEEACA8FD2413E525B6141F74637C15BB26`、Groundは
`15B5138A10D7EFE36AA33A8DC9657E39567023D72554BD3BBE473AC428971126`である。

fresh診断候補は[`20261012T112913347Z-ee4f241c`](runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261012T112913347Z-ee4f241c/)
で、candidate manifest SHA-256 `12350F09E47E798D06C478C54CBCD3DA4C2FC930459B839E54E09734495FD403`、final seal
`1C36990435DD1A44C14A4943F2D028054E037B420D7F1212ED2968E4C3DEB279`、Vehicle application
`FC8230F383840EFCFAFC7C100CB871AEAFD9D5B24923ADF70EBB3108E5AC4B9C`、Ground application
`01ABD6D764F216107D9B2BE18A9B4C154E2A2A96C8D8F5B2B41F599794167937`である。候補は
`runtime_fail_diagnostics_enabled=true`、`acceptance_eligible=false`、`acceptance_authorized=false`、
`deployment_authorized=false`である。

オフライン正本は
[`summary.json`](runs/validation/R19-HWCDC-SHORT-PACKET-TASK-PRIME-OFFLINE-001/20261012T205112080+0900/summary.json)、
SHA-256 `C4A690483C53925B8B973A450100FF358476636BF4F185F998FC53C95D270D00`、差分記録は同directoryの
`changes.patch`、SHA-256 `69BBB947C88BCF98BACB03E144C92A2EE8A0CFE08D161A3B42EC011BE96FB709`である。

本節ではCOM、JTAG、OpenOCD、flash、upload又は機器電源操作を行っていない。両XIAOはaccepted R18のままである。
**offline修正はPASSだが、R19実機修復、acceptance及びDeploymentはNO-GO継続**である。直前の一回限定許可はSection 31.30で
消費済みである。次は新しい一回限定許可と安全条件6項目再確認後に限り、上記sealed候補をapplication-onlyでVehicle→Groundへ
書込み、40秒dual-COM、両role record各2回、finally accepted R18 rollbackを実施する。COM3／COM6非0 byte及び短packet／
task-prime会計の収束を確認できた後、別許可で932/932を30秒以内、Heartbeat最大2,500 ms、全error／parser異常0を同時評価する。

### 31.32 short-packet／task-prime修正後の実機再診断と永久fail-stop原因確定（2026-10-12 JST、HIL）

新しい一回限定許可と安全条件6項目再確認後、Section 31.31のsealed診断候補
`20261012T112913347Z-ee4f241c`をapplication-onlyでVehicle→Groundへ書き込み、40秒dual-COM取得、両roleの
68-byte runtime-stage及び112-byte Endpoint FIFO record各2回読取り、finally accepted R18 rollbackを実施した。
outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T122306791Z-ff98986d/summary.json)、
SHA-256 `87194ADEEDC94653BFBDB2D684A4B3027BDD2D310B37AC95F65679A2F42EB79F`である。結果は
`FAIL / FAIL_STAGE_READ_R18_RESTORED`で、active-JTAG preflight、candidate install、両role record読取り及び
accepted R18 rollbackはPASSし、40秒captureだけが`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`だった。

captureではVehicle COM3、Ground COM6ともraw 0 byte、frame 0、serial write 0だった。最大service gapはVehicle
`58,937 us`、Ground `38,821 us`で、runnerの100 ms公平性上限内である。入力0 byteなのでparser cleanを通信PASSには
使用しない。capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T122306791Z-ff98986d/capture/summary.json)、
SHA-256 `5091B57F8FE1D2680976B786B95D11516B92B160E923477C6CBE131274FCD372`である。

両roleのruntime-stageは`0x00007fff`で`FlushCompleted`まで到達し、各recordは2回の読取りでbyte同一だった。主要な
実測値は次の通りである。

| 証拠 | Vehicle | Ground |
|---|---:|---:|
| first failure | `FlushFailed / 0x54520010 / 3538 ms` | `GroundBoundaryFlushFailed / 0x5452001c / 12899 ms` |
| FIFO attempt／bytes／zero | `4 / 126 / 0` | `3 / 84 / 0` |
| WR_DONE／IN_EMPTY／payload pickup | `4 / 5 / 4` | `3 / 4 / 3` |
| publish／pickup generation | `4 / 4` | `3 / 3` |
| ring／stash pending | `0 / 0` | `0 / 0` |
| ZLP | `0` | `0` |
| flush attempt／success／timeout | `6 / 1 / 5` | `7 / 1 / 6` |
| 最終状態 | `PayloadFlushPending` | `PayloadFlushPending` |

Vehicle record正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T122306791Z-ff98986d/stage_vehicle/summary.json)、
SHA-256 `FB395E7457222A0E0D169D09EC5636130194E519D8D616944BA32FED250214F6`、Ground record正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T122306791Z-ff98986d/stage_ground/summary.json)、
SHA-256 `F222ED5413105DD1A73837B14D02BE92D94669325A7C1BBACC8CEEFC133580AF`である。

この会計によりSection 31.30の二つの直接原因は解消方向へ進んだ。Vehicleの31-byte最終short packet及びGroundの後続
21 byteはともにFIFOへ正の長さで書かれ、publishとpickupが一致し、ring／stash残量及び不要ZLPは0である。従って今回の
0 byteを、Endpoint FIFOが動作しない、Ground task-primeが再び欠落した、又はshort packetにZLPを要求した結果とは分類しない。

残った直接原因は診断送信側のdeadlineと永久fail-stopの組合せである。完全な同一epoch payloadは後から
`FlushCompleted`へ到達している一方、先行する500 ms完了待ちがtimeoutした時点でfirst failureを保存し、
`r19_runtime_fail_diagnostic_transport_failed`を永久latchedして以後の診断frame生成を停止していた。このため、遅れて成立した
USB transaction完了を次周期へ引き継げず、COM readerが受信可能になった後も新規frameを送らない。Vehicleはcapture readerより
前のfail-stopが成立したことを証明できる。Groundも同じ会計に整合するが、本runのcapture schemaには各COM `.Open()`前後の
明示時刻がなかったため、その前後関係だけは確定せず、後続runnerへ時刻証拠を追加する。

本runはMission Planner protocol、MAVLink frame、E220 RF、TDD、Pixhawk UART、配線又は電源を直接原因とする証拠を
示していない。これらの経路を通る製品通信はcapture 0 byteのため未評価であり、正常とも異常とも判定しない。

rollback正本は
[`20261012T122310498Z-a4a824c9-rollback`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261012T122310498Z-a4a824c9-rollback/)
で、結果は`PASS_R18_ROLLBACK_COMPLETE`である。`flash_record.json` SHA-256は
`28A80BA92A350C1CA13A9EDBDE7E1C1BF1335684957B237B9AD61488579435EA`、`final_seal.json`は
`D631D22BCC8D352AEB72528D179EB35D3C3D4F43C3ED76F35DCC8044227A3499`である。Vehicleはaccepted R18
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Groundは
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`へ各attempt 1で復旧し、再列挙もPASSした。
終了時`power_off_required=false`である。本一回限定許可は消費済みで、追加の実機操作は行っていない。

### 31.33 bounded same-epoch flush-only復旧（2026-10-13 JST、offline完了）

Section 31.32で確定した診断専用の永久fail-stopに対し、TDD、E220、UART、MAVLink、pin又は通信速度へ触れず、
test-firstで限定的な復旧処理を追加した。500 msで検出したfirst failureは即時保存して上書きせず、次の全条件を満たす場合だけ
最大120秒の同一epoch recoveryをarmする。

- 対象payloadは既に完全frameであり、partial frameではない。
- `tx_loss_epoch`がfailure時から不変である。
- ring／stash及びegress backlogが空で、active ownerがない。
- Groundは保存したclean-boundary targetと現在のcommitted byte数が完全一致する。
- recovery deadlineを超えていない。

復旧処理は残存payloadを再送せず、USB flush完了の再確認だけを行う。成功時だけcadenceをcommitしpublisherをresetするため、
同一payloadの二重送信を避ける。epoch変更、partial frame、Ground target不一致又は120秒超過はfail-closedのままとする。
runtime-stageには`TransportRecoveryEntered`（bit 15）と`TransportRecoveryCompleted`（bit 16）を追加し、次回JTAGで
復旧経路への進入と完了を区別できるようにした。既知stage mask及びreader契約も新bitへ更新済みである。

全host suiteは310/310、独立focused recovery suiteは26/26、JTAG reader契約は117/117、dual-COM runner契約は45/45を
全てPASSした。focused suiteにはVehicle／Ground deadline、partial frame、boundary loss、epoch変更、Ground target不一致、
期限切れ、backpressure及びstarvationのfail-closed確認を含む。次回のpre-reader／post-reader判定を曖昧にしないため、
dual-COM runnerへrole別の`serial_port_open_before_utc`、`serial_port_open_after_utc`、
`serial_port_open_duration_ms`を追加した。runner self-testは`serial_write_calls=0`かつ`hardware_interaction=false`である。

Vehicle→Groundの順でArduino compile、封印、未公開artifact verifier、原子的`latest`公開及び公開後verifierを完了した。
正式診断候補は`20261012T151448091Z-3880c286`、Vehicle application SHA-256は
`B8E0871F914043CDB1E13902AF9366EE17E26E20198FD764BBE9A57BC07DF548`、Groundは
`DCC76C32BCAA676C8EE6D3A933F5105E35FAE0E5D56D5B6F8F9036365B996FD5`、`latest.json`は
SHA-256 `41FA55658E49A21F4A32FE3A142CD73AD65D30DAC2DE2B15A9AF6EEAC899AA9D`である。停止時に残った
`20261012T134412710Z-3dcdbd4b`も独立verifierで完全性を確認したが、手動公開せず証拠用のsealed orphanとして保持し、正式builderを
最初から再実行して新候補を公開した。

offline正本は
[`summary.json`](runs/validation/R19-DIAGNOSTIC-FLUSH-RECOVERY-OFFLINE-001/20261012T224858802+0900/summary.json)、
SHA-256 `DFF4E1A7F5FA8ECEC515E3F8C3F1C7EE37DE196B447818231A17FEEC2A2DC501`である。差分記録は同directoryの
`changes.patch`、SHA-256 `3BC5ED8C97149168E0D7EC236395495DA4A3F515CEAB51CEA590515D95BA30C5`である。

本節ではCOM、JTAG、OpenOCD、flash、upload又は機器電源操作を行っていない。両XIAOはaccepted R18のままで、
Section 31.32の許可は消費済みである。新候補は診断専用のため`acceptance_eligible=false`、
`deployment_authorized=false`であり、**offline修正はPASSだがR19 HIL、acceptance及びDeploymentはNO-GO継続**である。
次回は新しい一回限定許可と安全条件6項目再確認後に限り、上記候補をapplication-onlyでVehicle→Groundへ書込み、40秒dual-COM、
両role record各2回、finally accepted R18 rollbackを実施する。COM open時刻、recovery stage bit、同一epoch／no-replay会計、
COM3／COM6非0 byteを同時確認する。その後も別の受入許可で932/932を30秒以内、Heartbeat最大2,500 ms、
全error／parser異常0を同時達成するまでDeploymentを許可しない。

### 31.34 bounded recovery候補HILの再解析とR19F tail-stall診断契約（2026-10-13 JST、HIL再解析＋offline-only修正）

Section 31.33の正式診断候補`20261012T151448091Z-3880c286`を、新しい一回限定許可と安全条件6項目再確認後に
application-onlyでVehicle→Groundへ書き込み、40秒dual-COM取得及びfinally accepted R18 rollbackを実施した。outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T155736510Z-5abe6dc2/summary.json)、
SHA-256 `7891A71D90073604C710C0A87DBC4054884F035AA7A01716E43BDCB633610783`である。結果は
`FAIL / FAIL_CAPTURE_R18_RESTORED`だった。candidate installはPASSしたが、旧capture契約が
`FAIL_INVALID_R19F_REPEAT`で証拠を拒否したため、runtime-stage／Endpoint FIFO cause record読取りは実施されなかった。
その後のaccepted R18 rollbackは両roleともattempt 1でPASSし、終了時`power_off_required=false`である。

capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261012T155736510Z-5abe6dc2/capture/summary.json)、
SHA-256 `DC8CE413848C73FE352382F3DC70F089C55A25CC2960148D3A129765176ACA9F`である。実測は次の通りである。

| role | port | raw byte | 完全診断frame | partial | parser異常 | 最大service gap |
|---|---|---:|---:|---:|---:|---:|
| Vehicle | COM3 | 2,646 | R19A 42 | 0 | 0 | 237,406 us |
| Ground | COM6 | 662 | R19F 10 | 32 | 0 | 53,678 us |

旧runnerは1回の`Serial.Read`から複数frameを解析した場合、全frameへ同一の読取り完了時刻を付与した。このため同一batchに
入ったGround sequence 1と2を0 us間隔と誤認し、`FAIL_INVALID_R19F_REPEAT`にした。sequence 2→10の観測可能な間隔は
672,769〜1,012,782 usであり、旧判定は実通信のcadence failureを証明しない。一方、Vehicle最大service gap
237,406 usは100,000 us目標を超えているため、旧captureからrunner公平性PASSも宣言せず、修正runnerで再測定する。

実通信側には別の有意な証拠が残っている。Groundの完全R19Fはsequence 1〜10で連続し、全てsource line 3178、
同一failure snapshotだった。line 3178はGround USB heartbeat publicationを`Rejected`としてruntime fail-closedを
latchする位置である。`ground.raw.bin`は630 byteの完全frame列に続いて32 byteを持ち、総長662 byteだった。このsuffixは
sequence 10の次に期待されるsequence 11 R19F 63-byte frameの先頭32 byteとbyte単位で一致する。

```text
FD 33 00 00 0B FE BE FD 00 00 02 52 31 39 46 3A
47 3A 30 43 36 41 3A 30 30 30 30 30 30 30 30 30
```

従って現在の下り側直接証拠は、Mission Planner protocol、E220 RF、TDD又はPixhawk UARTの破損ではなく、R19 Groundの
USB CDC診断frameが開始され、1 chunk相当の32 byteだけhost-visibleとなった後、残り31 byteが旧capture中に現れなかった
ことである。ただし、Endpoint FIFO／flushのどのpredicateで停止したかは、旧outerがcause record読取り前に止まったため
未確定である。

この二つを分離するため、製品ファームウェアへ触れずrunner及びouterだけをtest-firstで修正した。runnerは
`read_batch_id`、`INITIAL / STARTUP_DRAIN / LIVE` origin、初回`BytesToRead`の一度だけのsnapshot、modulo-256 sequence連続性、
2本以上の観測可能LIVE間隔を導入した。終了時partialには不足byteだけを最大500 ms追加取得し、完全化できない場合でも、
raw末尾、expected next sequence、source binding、failure snapshot及び全parser counterを保存する。完全な次R19F prefixと
証明できた場合だけ`R19F_TERMINAL_PREFIX_STALL / FAIL_R19F_TERMINAL_PREFIX_STALL`へ分類し、PASSにはしない。

outerはこの明示的failureだけを、role/port、sequence、prefix、source、snapshot、raw offset、単一dirty role、tail timeout及び
他parser異常0を全て満たす場合に限りJTAG cause読取りへ進める。wrong sequence／prefix／role／source／snapshot、2 port、
他parser異常、tail未試行／例外、generic parser corruption及びinvalid repeatはfail-closedで拒否する。cause recordが読めても
最終状態は`FAIL_CAPTURE_R19F_TAIL_STALL_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`であり、accepted R18 rollbackを省略しない。

オフライン検証結果は次の通りである。

| 検証 | 結果 |
|---|---|
| runner test-first | RED 53件中7件、54件中1件、56件中1件を確認後、56/56 PASS |
| runner独立再実行 | 56/56 PASS、`hardware_interaction=false`、`serial_write_calls=0` |
| outer契約 | 19 offline scenario及び12 negative mutationをPASS |
| PowerShell parse | runner／runner契約／outer／outer契約の4ファイル、error 0 |

現行SHA-256は、runner
`2EC19AE4C9F0E59A7DEFE335DA9184BEEBB51B154D5655BCD0560FA217C83727`、runner契約
`3F528CAA38C436FDFAF6410ACEB9833DC02001067EAD3579B0A405CEDD047026`、outer
`B15A43F3DB42628461E02AE237F3A033778D94C7C28B4C346DD393138FC2A5DE`、outer契約
`DD41780DBE397457A85D400F426B629506389769C5B2D3E3625FC60A6A6EF83D`である。PowerShell 7からouter契約を直接起動した
最初の確認は、Windows PowerShellを`$PSHOME`から要求する既存fail-closed条件によりscenario開始前に停止した。同一契約を
Windows PowerShell 5.1で再実行してPASSしており、これはlauncher環境差であって製品failureではない。

オフライン正本は
[`summary.json`](runs/validation/R19-RUNTIME-CAPTURE-TAIL-STALL-POLICY-OFFLINE-001/20261013T014833807+0900/summary.json)、
SHA-256 `83A6DDA94345DF95D9F1DB513550A16F10D77779D01F250987C07B0506782C87`である。差分記録は同directoryの
`changes.patch`、SHA-256 `F358026445786A0E9D80B7A148141C6C79AC89DC7E4F950E7225877E8378EE63`である。

本offline修正ではfirmware、embedded core、candidate、`latest.json`、TDD、E220/UART、pin、MAVLink routingを変更せず、
COM、JTAG、OpenOCD、flash、upload又は電源操作も行っていない。firmware変更がないためArduino再compileは対象外である。
現在のVehicleはaccepted R18
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Groundは
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`で、直前の一回限定許可は消費済みである。

次の実機作業には新しい一回限定許可と安全条件6項目再確認が必要である。同じsealed candidateをapplication-onlyで
Vehicle→Groundへ書込み、修正runnerで40秒dual-COMを取得する。完全frameへ収束すれば新しい通常証拠として評価し、
厳密なnext-R19F terminal-prefix stallが再現した場合だけ両role cause recordを読み、finally accepted R18へ復旧する。
R19 acceptance／Deploymentは**NO-GO継続**であり、その後の別受入runで932/932を30秒以内、Heartbeat最大2,500 ms、
runner公平性100 ms以下及び全error／parser異常0を同時に証明するまで合格としない。

### 31.35 host-tool修正後のArduino clean compile確認（2026-10-13 JST、offline-only）

Section 31.34のrunner／outer修正後、`AGENTS.md`の検証順序に従い、sealed診断候補
`20261012T151448091Z-3880c286`を変更せずVehicle→Ground順にclean compileした。先に独立artifact verifierを実行し、
candidate manifest、seal及び63件のcanonical source recordを再検証した結果、不一致は0だった。

compile条件はArduino CLI `1.5.2-rc.1`、ESP32 core `3.3.11`、FQBN
`esp32:esp32:XIAO_ESP32S3`、`VC_LORA_R19_HIGH_SPEED_CANDIDATE=1`及び
`VC_LORA_R19_RUNTIME_FAIL_DIAGNOSTICS=1`である。結果は次の通りである。

| role | 結果 | flash | RAM |
|---|---|---:|---:|
| Vehicle | PASS | 439,073 byte | 106,456 byte |
| Ground | PASS | 411,461 byte | 70,064 byte |

各roleでbuild-path BINと隔離output-directory BINはbyte一致した。sealed candidateとの再生成差は各70 byteで、
32-byte build identity、compile-time ASCII 5 byte及びそれに依存するterminal image digest 33 byteだけだった。
その他のbyteは一致し、sealed candidate、`latest.json`及びsourceは変更していない。`latest.json` SHA-256は引き続き
`41FA55658E49A21F4A32FE3A142CD73AD65D30DAC2DE2B15A9AF6EEAC899AA9D`である。

compile正本は
[`summary.json`](runs/validation/R19-POST-TOOLS-ARDUINO-COMPILE-001/20261012T165612407Z-compile/summary.json)、
SHA-256 `B2C7CA0EB1625D0DB1C136B204335225BAA6CB62289399B57DABF027E730A6DA`である。検証記録は同directoryの
`changes.patch`、SHA-256 `86F9622B27ADD9CA31113BD51A16BE1824559C2DBD71A49B547876597383752F`である。

本節ではflash、upload、COM、JTAG、OpenOCD又は電源操作を行っていない。両XIAOのaccepted R18状態、
Section 31.34のNO-GO判定及び次回実機試験に新しい一回限定許可が必要という条件は変わらない。

### 31.36 一回限定HILの書込み前停止とcandidate生成物隔離（2026-10-13 JST）

新しい一回限定許可及び安全条件6項目再確認後、Section 31.34の修正済みouterで診断候補
`20261012T151448091Z-3880c286`の一回限定HILを開始した。COM3／COM6 identity、candidate／runner／outer hash、
競合process及びactive JTAGは事前確認を通過したが、candidate installのinitial verifierが
`Candidate artifact must contain exactly two app-only binaries`で停止した。40秒capture及びcause record読取りは実行されなかった。

outer正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261013T141058898Z-1828c3ad/summary.json)、
SHA-256 `6A0E9A661A41DC41E2623A683A65606C3096A8F8D82816A41449E4B273EC9DE1`である。最終状態は
`FAIL / FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED`で、一回限定許可は消費済みである。

install正本
[`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261013T141059416Z-b0ded8ce-install/flash_record.json)、
SHA-256 `A173EA10938468C8584EAB70BD23194A66472C4004CD091741D7F6508E3CCC25`は、次の全項目を明示する。

- `status=FAIL_STOP_BEFORE_CANDIDATE_WRITE`
- `device_access_attempted=false`
- `esptool_executed=false`
- `firmware_write_attempted=false`
- `firmware_may_have_changed=false`
- erase、bootloader、partition table及びmerged image writeは全てfalse

従って本runではR19 candidateもR18 rollbackも書き込まれず、直前に証明済みのaccepted R18を変更していない。rollbackは
同じcandidate verifierでdevice access前に停止したため、outerは安全側に`unproven`とし、`power_off_required=true`を返した。
これは実書込み失敗ではなく、rollback完了をrun内で再証明できなかったことによるfail-closed判定である。

直接原因はSection 31.35のisolated compile時に、Arduino CLIがsealed package内の各role sketchへ`build/`を生成したことである。
2 directory合計22ファイル中10個が追加`.bin`で、sealed app-only 2個と合わせcandidate内の`.bin`が12個になった。
これらはsealed manifest対象外だったが、verifierのexact inventory条件を正しく発火させた。

追加生成された2個の`build/`は削除せず、次の検証directoryへ隔離した。

```text
runs/validation/R19-POST-TOOLS-ARDUINO-COMPILE-001/
  20261012T165612407Z-compile/quarantined_candidate_build/
```

隔離後のcandidate内`.bin`は元の2個だけとなり、独立verifierは元のartifact ID、manifest、seal、Vehicle／Ground application
SHA-256でPASSした。candidate source、sealed binary、manifest、seal、handoff及び`latest.json`は変更していない。

オフライン是正正本は
[`summary.json`](runs/validation/R19-CANDIDATE-GENERATED-BUILD-QUARANTINE-OFFLINE-001/20261013T231601375+0900/summary.json)、
SHA-256 `D4C5E888D7ECD8DAB1596653B82F353CC1C096F83F39B395C4D011571C4D7D78`、記録は同directoryの
`changes.patch`、SHA-256 `628AF61A2EA5126A20ECA38AA59682EE087846433D99FE8E7647150BEADF674C`である。

実機への追加操作は行っていない。operatorの全電源OFF確認及び、別許可によるaccepted R18状態再証明が完了するまで、
両bridgeの操作とR19再試験は禁止する。R19 acceptance／Deploymentは**NO-GO継続**である。

### 31.37 operator全電源OFF確認の追記（2026-10-13 JST）

Section 31.36の全電源OFF依頼に対し、operatorから`電源OFF完了`の確認を受領した。確認対象は、Ground／Vehicle両XIAOの
USB及びPixhawkを含む外部電源を全て外し、5秒以上OFFを維持するという依頼全体である。本追記時にはCOM、JTAG、
OpenOCD、esptool、flash、upload又はdevice readを行っていない。

本確認はoperator申告の記録であり、電圧の独立計測又はfirmware readbackではない。従って、Section 31.36のlive-run正本と
`FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED`は当時の履歴として変更しない。一方、要求した電源OFF containmentは
operator確認により完了したものとして扱う。

確認正本は
[`summary.json`](runs/validation/R19-OPERATOR-POWER-OFF-CONFIRMATION-001/20261013T232312529+0900/summary.json)、
SHA-256 `C423364AC63F09F95577915BADE375E16FA992E7AE9E745E007B94CC88D567F4`である。記録は同directoryの
`changes.patch`、SHA-256 `7D7AD95D6683957BA83D33EB60F9F5D064E4F929F2BD3F01693135A695A44C43`に保存する。

Section 31.36のrunはdevice access前に停止し、R19及びR18の書込みを一切行っていないため、accepted R18は直前状態から
変化していないと判断できる。ただし電源OFF後の現在状態をreadbackで再証明したものではない。一回限定許可は消費済みで、
R19 acceptance／Deploymentは**NO-GO継続**である。次の実機操作は、再接続、安全条件6項目の再確認及び新しい明示的な
一回限定許可を受けた後、accepted R18のreadback確認を先行し、不一致が証明された場合だけR18を復旧する。

### 31.38 accepted R18再証明tooling監査と一回限定live fail-safe停止（2026-10-14 JST）

Section 31.37後のaccepted R18再証明に先立ち、専用runnerをtest-firstで作成し、実機へ触れない独立監査を完了した。
正本は
[`summary.json`](runs/validation/ACCEPTED-R18-REPROOF-TOOLING-OFFLINE-001/20261014T004117594+0900-D/summary.json)、
SHA-256 `1077AB15E464BC81C6EA980CAFA2EEB5A54AC27581F88F29E44A0EA6041B04C2`である。
最終sealは同directoryの[`final_seal.json`](runs/validation/ACCEPTED-R18-REPROOF-TOOLING-OFFLINE-001/20261014T004117594+0900-D/final_seal.json)、
SHA-256 `AB34AF5E3D1904C173326D3522135B27F18CD76D04405B5689D5FC7B3879F71B`である。

監査結果は`PASS_P1_EXACT_USB_ROLE_AND_EMERGENCY_TERMINAL_HARDENING`で、独立read-only auditは`P0=0 / P1=0`、
Windows PowerShell 5.1及びPowerShell 7の双方で13 scenarioがexit 0でPASSし、hardware accessは0だった。対象fileは次である。

| file | SHA-256 |
|---|---|
| `tools/invoke_accepted_r18_reproof_hil.ps1` | `7BB1AA356BD6B67E82B6323AFF32114A67FAC8386C654140EFEF3FD9E46CCE24` |
| `tests/hil/check_accepted_r18_reproof_orchestrator_contract.ps1` | `205A4A03D5C10836523A11D739B24B778CECB48A7EF37895255378C871E567A9` |

runnerの固定契約は、app offset `0x10000`からrole別の完全長readbackを先に行い、expected application SHA-256との不一致が
完全長で証明されたroleだけを書き戻すことである。accepted R18固定値はVehicle `389280 bytes`／
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground `360208 bytes`／
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`である。汎用error又は不完全readbackを
firmware mismatchとして扱わず、その場合は書き込まない。

新しい一回限定許可及び安全条件6項目確認後、この監査済みrunnerでlive再証明を1回実施した。正本は
[`summary.json`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T154540135Z-81d120ac/summary.json)、
SHA-256 `9B2F64C59E49264187B11AF531E85553907499506011D90E9FE9541424F70B36`、最終sealは
[`final_seal.json`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T154540135Z-81d120ac/final_seal.json)、
SHA-256 `0603A08D6ADE50547525BE2F5A312F0B4A89FDAB07D21772A6EB610E0CDEEE36`である。

Vehicle COM3はPnP parent及びMAC照合をPASSし、esptool 5.3.1でoffset `0x10000`、長さ`389280 bytes`のread-flashを開始した。
stdoutに記録された最終進捗は`102400 / 389280 bytes`（26.3%）で、その後hard reset requestを出してexit `255`となった。
raw stdout SHA-256は`06E676B8578362F2F4AC9E5376C361A4F3DECDF6F629CB58BDAAF0AC1D2A59BA`、exit recordは
`A730E9F4FECEF62A7023B1B3B6B11312E9689EF5A5C2109737BC7E12DB929948`である。full-length readbackは成立せず、
Vehicleの一致又は不一致は証明されなかった。exit `255`の原因は本証拠では確定していない。

hard reset request後、Vehicleのexact USB roleは同じPnP device／parentで再列挙され、証拠
[`01_vehicle_readback.reenumeration.json`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T154540135Z-81d120ac/01_vehicle_readback.reenumeration.json)、
SHA-256 `7B2BFB6B373FC7572489F6CAC9AC793963E231BEE3D12579B236FB4058EDA07B`に`proven=true`として保存された。
これはUSB roleの存在を証明するが、application liveness又はaccepted R18 contentを証明するものではない。

| role | identity／read-mac | full-length readback | mismatch proven | write／erase | 本runでのaccepted R18証明 |
|---|---|---|---|---|---|
| Vehicle | PASS／PASS | FAIL（`102400 / 389280`、exit `255`） | false | 0／0 | false |
| Ground | 未実施 | 未実施 | false | 0／0 | false |

最終statusは`FAIL_DEVICE_TARGETING_OPERATION_EXACT_USB_ROLE_PROVEN_NO_WRITE`である。`firmware_write_attempted=false`、
`firmware_may_have_changed=false`、erase／bootloader／partition table／merged image writeは全てfalseで、Groundの
`device_operation_count=0`である。従ってGroundは本runで未操作であり、Vehicleにも書込みは行われていない。一方、完全長readbackが
成立しなかったため、本run単独では両roleともaccepted R18を証明していない。一回限定許可は消費済みで再利用不可、
`power_off_required=false`、`live_flash_authorized=false`である。R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.39 accepted R18安全readbackのオフライン是正（2026-10-14 JST、offline-only）

Section 31.38の一回限定live再証明では、Vehicleの`read-flash`が`102400 / 389280 bytes`で停止し、実processは
exit `255`となった。完全長readbackは成立せず、firmware mismatchは証明されなかった。書込み及びeraseは0、Groundは
`device_operation_count=0`で未操作である。従って本run単独ではVehicle／Groundのどちらもaccepted R18を証明しておらず、
一回限定許可は消費済みである。

この停止はLoRa、E220、TDD又はR18 application内容を通る前の、PCからVehicle XIAOへのesptool bulk-read中に発生した。
従ってそれらを原因とする証拠ではない。現時点の有力仮説は、esptool 5.3.1のdefault stubを使用したbulk-read transportの
停止である。ただし、前回runnerはprocess exit `255`の由来を十分な粒度で保存していなかったため、根本原因は未確定とする。

実機へ触れず、専用runnerをtest-firstで次のfail-closed契約へ修正した。

- role identity及びMAC一致後、accepted R18 imageに対する`verify-flash`を先行し、成功時はbulk read及びwriteを行わず一致とする。
- verify失敗又は成功marker欠落は`mismatch`ではなく`ambiguous`とし、必要時だけfull readbackへ進む。
- fallback full readbackは`--no-stub`、`--baud 115200`、`--flash-size 8MB`、`--no-progress`に固定する。
- full-length成立かつSHA-256不一致の場合だけmismatchを証明し、writeを許可する。
- write関数内部にも独立したproven-mismatch gateを置き、上位判定の誤用だけではprocessを開始できない。
- 実process exit、例外型／message／FQID、正確なargv及びhash、stdout／stderr、output file、最終進捗byte／address、
  exact-role再列挙証拠へのlinkをrole別operation recordへ保存する。
- post-write最終readbackにも同じROM no-stub／115200 bps経路を使用し、不完全fileを再利用しない。

さらに、manifest対象path setと実directory file setの完全一致、entry count及びpath-set hashをsealへ固定した。
process argumentは空文字、空白を含むpath、末尾backslash及び埋込みquote／backslashを実子processへ渡して往復一致を確認する。
write／verify transportの`921600 bps`、accepted R18 image、firmware source、COM3／COM6 identity、UART、TDD、E220、pin及び
RF設定は変更していない。対象file及び固定SHA-256は次である。

| file | SHA-256 |
|---|---|
| `tools/invoke_accepted_r18_reproof_hil.ps1` | `7B4631CBF5472CB4E88BFEFC109EDD0BF4865BF448B3CA4B281C477D18FD8F37` |
| `tests/hil/check_accepted_r18_reproof_orchestrator_contract.ps1` | `75CA03CBE173A55641581733F75E61B4AE68699204BF1890F0E4F2EFDA37464D` |

Windows PowerShell 5.1及びPowerShell 7の双方で20/20 scenarioをPASSした。`102400 / 389280 bytes`での中断、exit 0だが
wrong size、verify成功によるreadback skip、verify失敗後のfull match、verify失敗後のfull mismatch及び両経路失敗を含む。
追加fileをseal後に置くmanifest負例1件は拒否され、argument round-trip 6値もPASSした。全offline testで
`hardware_accessed=false`、書込み対象外caseはwrite 0であり、独立監査は`P0=0 / P1=0 / P2=0`だった。

オフライン正本は
[`summary.json`](runs/validation/ACCEPTED-R18-SAFE-READBACK-OFFLINE-002/20261014T014232615+0900/summary.json)、
SHA-256 `F28B4DAA6F2DBACDD32361720F2930F2FDE08F3630AA390C1DB0C505B95AE588`である。manifestは同directoryの
[`SHA256SUMS.txt`](runs/validation/ACCEPTED-R18-SAFE-READBACK-OFFLINE-002/20261014T014232615+0900/SHA256SUMS.txt)、
SHA-256 `57144CACB28E036FC4B8CF8657152140520518CDBF1F7BE63E921E029306E6EE`、最終sealは
[`final_seal.json`](runs/validation/ACCEPTED-R18-SAFE-READBACK-OFFLINE-002/20261014T014232615+0900/final_seal.json)、
SHA-256 `C3A5BBD7059D43D68D114FB70AA11D3F332DD1A340C585C19B6B2A4578CC2C7B`である。

本節の修正及び検証ではfirmware、COM、JTAG、OpenOCD、esptool、flash、upload又は機器電源操作を行っていない。
従って新しい実機retryには、改めて一回限定許可と安全条件6項目の再確認が必要である。次回もaccepted R18のverify-firstを
Vehicle→Groundの順で実施し、proven mismatchとなったroleだけをapplication-onlyで復旧する。R19書込みは引き続き禁止し、
R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.40 Arduino compile監査とsealed candidate／accepted R18 baseline分離（2026-10-14 JST、offline-only）

Section 31.39のreadback tooling修正後、`AGENTS.md` rule 8に対応するArduino compile状態をofflineで監査した。
標準経路`tools/compile_arduino.ps1`は`FW-ARDUINO-CONTRACT-001`でcompile開始前にfailした。正本は
[`summary.json`](runs/validation/R19-TOOLING-RULE8-ARDUINO-COMPILE-001/20261013T165306721Z/summary.json)、
SHA-256 `9118B92BB03CA8908C2259A0E7450B74E60B163BFABA43509C6D806B65DD32F5`である。この標準summaryは
fail-fastにより最初のadapter mismatchだけを報告するため、root sketch copy全体のread-only hash auditを追加した。

完全監査ではVehicle及びGroundの各roleで2 file、合計4 copy mismatchを確認した。

| 相対path | canonical SHA-256 | Vehicle／Ground copy SHA-256 | mismatch |
|---|---|---|---:|
| `vc_lora_phase6_bridge.hpp` | `B7F779BB042854B37CC6B03F359EA492F124F40A5776BB8389BCA94CA94060B6` | `C3B90E42F8AC008099B2ABA470942E46AA01107785FED4A6833702B5AF28AA48` | 2 |
| `high_speed/r19_runtime_stage_record.hpp` | `0B7E757DE5679E10075D62101AA6427AD7CB9F01920F4C94BF252D309640FB67` | `53A3713EA26EAB9547C4F3222D473EA3681AEF6001A270E9CDD6DEE39716A72D` | 2 |

root sketch copyはcanonicalより古い。canonical側の変更時刻及び関連証拠は2026-10-12のR19 diagnostic flush-recovery作業と
一致する。従ってこの不一致は今回のaccepted R18 safe-readback tooling変更により生じたものではない。標準summaryの
最初の1件だけの報告よりも、6 fileを直接再計算した上記4件の完全監査を現在のcopy状態として優先する。

標準root sketchを同期せず、既に封印済みのR19診断候補`20261012T151448091Z-3880c286`だけをVehicle→Ground順で
clean compileした。両roleはPASSし、結果は次の通りである。

| role | compile | flash | RAM |
|---|---|---:|---:|
| Vehicle | PASS | 439,073 byte | 106,456 byte |
| Ground | PASS | 411,461 byte | 70,064 byte |

正本は
[`summary.json`](runs/validation/R19-SEALED-CANDIDATE-RECOMPILE-001/20261013T165407309Z/summary.json)、
SHA-256 `ADA4CC798CD5E3EFD457726CEF3887C1A1C61D71B8332359FD2E22800520D4A8`である。Arduino CLIがpackage sketch下へ
生成したVehicle／Groundの`build/`はcandidate manifest及び`SHA256SUMS.txt`の対象外であることを証明後、削除せず同validation
証拠の`generated_build_quarantine/`へ退避した。退避後、official candidate verifierは再度PASSし、sealed application binary、
`latest.json`及びcandidate sourceは不変だった。このcompile PASSはsealed診断候補packageだけに適用し、標準canonical
compileのFAILを上書きしない。

保存済みaccepted R18 baselineもread-onlyで再検証した。
[`snapshot.json`](runs/baselines/R18-PRODUCTION-R4-ACCEPTED/20260914T225054625Z/snapshot.json)は
SHA-256 `C3F121EF021BB8C9FCF142890BCD69260D3BDEB54690FADCA8EBC14B6B46C023`で、120/120 source、mismatch 0、
source tree SHA-256 `949F6771CEC61B448C2B9FE648C40DB374C9E8DC5DF13B2653BC887C8F527CF9`を保持する。accepted R18
Vehicle application SHA-256は`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Groundは
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`で、両bin hashはPASSした。baseline artifact summaryは
[`summary.json`](runs/baselines/R18-PRODUCTION-R4-ACCEPTED/20260914T225054625Z/artifacts/summary.json)、
SHA-256 `09E748985E1A745BD2B87A25C7A3F5DBA3827D52DE644F7F7CE9BE107936D6E7`である。これは保存artifactの完全性を示すもので、
現在の実機application contentを新たに証明するものではない。

root sketch copyの同期は別のfirmware work itemとし、本作業では禁止して実施していない。firmware source、sealed candidate、
accepted R18 baseline及び`latest.json`は変更しておらず、COM、JTAG、OpenOCD、esptool、upload、flash又は機器電源操作も0である。
新しいlive retryには改めて一回限定許可と安全条件6項目の再確認が必要である。R19書込みは引き続き禁止し、R19
acceptance／Deploymentは**NO-GO継続**とする。

### 31.41 production root sketch exact4同期とaccepted R18両role実機再証明（2026-10-14 JST）

Section 31.40で隔離したproduction root sketchの4 copy mismatchを、別のoffline firmware work itemとしてcanonicalへ同期した。
変更対象は次の4 fileだけである。

| production root copy | 同期前SHA-256 | 同期後／canonical SHA-256 |
|---|---|---|
| `vc_lora_vehicle_xiao_esp32s3/vc_lora_phase6_bridge.hpp` | `C3B90E42F8AC008099B2ABA470942E46AA01107785FED4A6833702B5AF28AA48` | `B7F779BB042854B37CC6B03F359EA492F124F40A5776BB8389BCA94CA94060B6` |
| `vc_lora_ground_xiao_esp32s3/vc_lora_phase6_bridge.hpp` | `C3B90E42F8AC008099B2ABA470942E46AA01107785FED4A6833702B5AF28AA48` | `B7F779BB042854B37CC6B03F359EA492F124F40A5776BB8389BCA94CA94060B6` |
| `vc_lora_vehicle_xiao_esp32s3/high_speed/r19_runtime_stage_record.hpp` | `53A3713EA26EAB9547C4F3222D473EA3681AEF6001A270E9CDD6DEE39716A72D` | `0B7E757DE5679E10075D62101AA6427AD7CB9F01920F4C94BF252D309640FB67` |
| `vc_lora_ground_xiao_esp32s3/high_speed/r19_runtime_stage_record.hpp` | `53A3713EA26EAB9547C4F3222D473EA3681AEF6001A270E9CDD6DEE39716A72D` | `0B7E757DE5679E10075D62101AA6427AD7CB9F01920F4C94BF252D309640FB67` |

production root 2 treeをbuild directory除外で比較した結果は124 file中120 unchanged／4 changed／missing 0／added 0で、
変更数はexactly 4だった。Windows PowerShell 5.1及びPowerShell 7でfirmware contractとhigh-speed packaging contractをPASSし、
host CTestは310/310、internal aggregationは275 PASS／expected XFAIL 2／unexpected FAIL 0だった。13個のcanonical
high-speed headerを両roleへ照合した26 comparisonもmismatch 0である。通常Arduino compileはVehicle→Ground順でPASSした。

| role | flash | RAM | application binary SHA-256 |
|---|---:|---:|---|
| Vehicle | 390,613 byte | 101,920 byte | `2BEE31FD77D9ED183200750C19EA3B8F688302036B8F9041ED2339519664F688` |
| Ground | 360,849 byte | 65,512 byte | `82D9806436C9CC391C56F818C9A5C9C796AC0D6B617884468DF0127A51226928` |

このcompileはflashを行っていない。既存sealed R19診断候補`20261012T151448091Z-3880c286`、`latest.json`、accepted R18
baseline及びstable diagnostic sketchは変更されていない。独立監査は`P0=0 / P1=0`で、既知の`P2`は同期済みcanonical
Ground compileにおける未使用変数`disposition`のwarning 1件だけであり、build自体は成功している。

exact4同期のoffline正本は
[`summary.json`](runs/validation/ROOT-SKETCH-CANONICAL-SYNC-OFFLINE-001/20261013T224459573Z/summary.json)、
SHA-256 `45A6A58FDD52FFDEF43AB7E2CF029518C9CD5ECB374C42F0DC0AED9866880713`である。同directoryの
[`changes.patch`](runs/validation/ROOT-SKETCH-CANONICAL-SYNC-OFFLINE-001/20261013T224459573Z/changes.patch)は
`6113B612B6C464CBA32896CF4586D791D88A59E3F7FD1C19D253ABF577A7C5DC`、
[`SHA256SUMS.txt`](runs/validation/ROOT-SKETCH-CANONICAL-SYNC-OFFLINE-001/20261013T224459573Z/SHA256SUMS.txt)は
`3E24B7C61E9E0819CBCED390CA20CD1ABAA61E52720FB9B481F12A0C2895BB0A`、
[`final_seal.json`](runs/validation/ROOT-SKETCH-CANONICAL-SYNC-OFFLINE-001/20261013T224459573Z/final_seal.json)は
`C89FA741ED273F16A511B7E91E06A148A81178EB2FD4DAF9EEA0000201E236D0`である。この作業ではCOM、JTAG、OpenOCD、
esptool、upload、flash又は機器電源操作を行っていない。

その後、Section 31.39のverify-first runnerを新しい一回限定許可と安全条件6項目確認の下で実機実行した。正本は
[`summary.json`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T230600394Z-ec66e6e1/summary.json)、
SHA-256 `3F8A79F26457013C3918A82A1D9F64F69D55C76890CA72C6F842E43C35E20268`で、最終statusは
`PASS_R18_ALREADY_ACCEPTED_BOTH`である。

| role | port | exact identity | read-MAC | pinned verify | 証明したapplication SHA-256 | write／erase |
|---|---|---|---|---|---|---|
| Vehicle | COM3 | PASS | PASS | MATCH | `9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52` | 0／0 |
| Ground | COM6 | PASS | PASS | MATCH | `30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5` | 0／0 |

両roleともpinned `verify-flash`が一致したため、fallback full readback及びrestoreは不要だった。各操作後のexact USB role再列挙も
PASSし、`firmware_write_attempted=false`、`firmware_may_have_changed=false`、erase／bootloader／partition table／merged image
writeは全てfalseである。一回限定許可は`consumed=true / reusable=false`、終了時`power_off_required=false`である。

live証拠の[`SHA256SUMS.txt`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T230600394Z-ec66e6e1/SHA256SUMS.txt)は
SHA-256 `639060AB533D29262BACA5D1383D05E41F54FA376C45B73C11DEC0AE45F40C02`、manifest path-set SHA-256は
`BB88593FC6C30B560CCEEFB70B8200A0B4FEF3DBA1990C944D62EC82EA51E02E`、
[`final_seal.json`](runs/hil/ACCEPTED-R18-REPROOF-HIL-001/20261013T230600394Z-ec66e6e1/final_seal.json)は
SHA-256 `CF972C8E5AFE12C52585BE26879402016FD42B31CE347DE03C17E0673E2B574B`である。独立post-run reviewは
`P0=0 / P1=0`だった。

ただし本runが証明したのは、COM3／COM6の期待した両XIAOに、固定したaccepted R18 application imageと一致するflash内容が
存在することだけである。application livenessは`false`であり、起動後のUSB CDC、MAVLink、Pixhawk、E220、RF、TDD、上り／下り
通信及びMission Planner接続は試験していない。また、一回限定tokenの消費／再利用禁止は証拠へ保存されているが、許可の一意性を
外部grant IDへ暗号学的に結び付けたものではない。sealはmanifest・path set・file hash間で内部整合するが、外部署名された
attestationではない。これらを独立reviewの`P2`制限として保持する。

従って本結果を通信liveness、R19 acceptance又はDeploymentの合格へ拡張しない。R19書込みは引き続き**禁止**し、R19
acceptance／Deploymentは**NO-GO継続**とする。次に通信を評価する場合は、このaccepted R18 flash identity証明とは別の明示的な
試験範囲、許可及び安全確認を必要とする。

### 31.42 accepted R18単一PARAM liveness live停止原因とrunner修正（2026-10-18 JST）

新しい一回限定許可、安全条件6項目確認及び同時5秒以上OFF後のcold boot attestationの下で、accepted R18の
単一`PARAM_REQUEST_READ` liveness試験を実行した。live正本は
[`summary.json`](runs/hil/R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001/LIVE-20261018T093557570Z-6a90e296/summary.json)、
SHA-256 `979F21875F00EFF24CF1F805A45B4ECF096FC91CD7701E868E9BA856A03A8997`である。最終sealは同directoryの
[`final_seal.json`](runs/hil/R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001/LIVE-20261018T093557570Z-6a90e296/final_seal.json)、
SHA-256 `CC94B61624FAA45FCBDDEC80F946F50143A6710098B67D7C457191E2E09FD6E8`である。

公式live結果は`FAIL`だが、製品通信のFAILではない。COM6をexact identityでopen後、最初のreadで266 byteを取得した。
このrawは許可済みESP32-S3 ROM起動bannerの固定SHA-256
`18D9E462805F310BC60FCE7C40CF998DE6F9B4EF1EE1E6A0FC652E82CB71A5EC`と完全一致した。MAVLink frameは0、
request attemptは0、request write完了は0、outcomeは`NOT_ATTEMPTED`である。serial write、firmware write、E220 write及び
actuator commandは全てfalseだった。cleanupは7/7 PASS、COM close／dispose済み、終了後open=falseである。一回限定許可は
`consumed=true / reusable=false`であり、再利用しない。

停止原因は`Wait-HeartbeatPreflight`内のPowerShell collection shapeである。fresh Heartbeatが0件のとき、
`if ... else {@()}`の式出力が`$null`となり、StrictMode下の`$lastTwo.Count`が例外になった。従ってrequest boundary、
32-byte `PARAM_REQUEST_READ`送信、Pixhawk応答、E220／RF／TDD及び下り通信は本runで未評価であり、本結果からそれらの
正常／異常を判定しない。

実機を再操作せず、`empty_preflight_heartbeat_collection_is_scalar_safe`契約を先に追加した。修正前はWindows PowerShell 5.1で
22件中当該1件だけFAILした。その後、2箇所の`$lastTwo.Count`を`$lastTwoCount=@($lastTwo).Count`へ変更し、0件及び1件を
安全に待機させた。異なるread ordinal、正の時刻差を持つ2件のfresh Heartbeat、2,500 ms上限及びその他全gateは変更していない。
修正後はWindows PowerShell 5.1及びPowerShell 7の双方で22/22 PASSした。修正後runner SHA-256は
`9A80A74460E5DC905F4005538A8E323959CD63D7E6179F2F3AA414907B94BF88`、契約SHA-256は
`055C153A90436FE704A68FFDEDAE0195FD1DFF3232CC4E04983738F9605713E6`である。

標準Arduino compileはVehicle→Ground順でPASSした。VehicleはFlash 390,613 byte／RAM 101,920 byte、Groundは
Flash 360,849 byte／RAM 65,512 byteで、HWCDC integrity、firmware contract及びmanifest verifyもPASSした。実機flashは
行っていない。オフライン修正報告は
[`REPORT.md`](runs/validation/R18-LIVENESS-EMPTY-PREFLIGHT-FIX-001/20261018T094018794Z/REPORT.md)、
SHA-256 `E7F5D47EBF55D4B1EA33DFFD26D93BB423B968D8072F39CFF12BDFE58E4B7825`、構造化結果は
[`summary.json`](runs/validation/R18-LIVENESS-EMPTY-PREFLIGHT-FIX-001/20261018T094018794Z/summary.json)、
SHA-256 `35A606EAC27C1DD4FC538F430EE1AA53E1D0E08903F703FFFECFFB5960C21B3B`である。最終sealは同directoryの
[`final_seal.json`](runs/validation/R18-LIVENESS-EMPTY-PREFLIGHT-FIX-001/20261018T094018794Z/final_seal.json)、
SHA-256 `DA30484CF5E4479C4D6B4210A5B90F4614496A8915BDE1C7DEAC9F1D036CCFF0`である。

従ってrunnerの空Heartbeat処理は修正済みだが、実機通信受入は未完了である。次回live retryには新しい一回限定許可、
安全条件6項目再確認及びcold bootが必要である。R19書込みは引き続き禁止し、R19 acceptance／Deploymentは
**NO-GO継続**とする。

### 31.43 R18 runnerの起動表示・timeout修正と単一PARAM実機PASS（2026-10-19 JST）

前回の`LIVE-20261018T121735247Z-79f9471d`では、正常な265-byte起動表示`boot:0xb`を
固定266-byte `boot:0x2b`しか許可しないrunnerがnoise化し、正常Heartbeat 2件受信後も要求送信前に停止した。
別の`LIVE-20261018T152916883Z-4b2527fd`は90秒間raw 0 byte、pump最大61.341 msであり、
両者は異なる観測として保持する。

test-firstで2種類の完全一致allowlist、timeout時の受信／parser／Heartbeat snapshot、
COM open前の分離した疑似readによる事前準備、実測parse区間時刻を追加した。
変異、未登録表示、途中切れを許可せず、2,500 ms Heartbeat、100 ms pump、fresh Heartbeat 2件、
exact32-byte PARAM_REQUEST_READ一回限定、COM6限定を維持した。
PowerShell 5.1／7はいずれも契約26/26、動作46/46 PASS。Vehicle→Ground Arduino compileもPASS。
変更前後のsource、差分、検証結果は
[`REPORT.md`](runs/validation/R18-LIVENESS-BOOT-BANNER-TIMEOUT-FIX-001/20261018T154359465Z/REPORT.md)及び
[`summary.json`](runs/validation/R18-LIVENESS-BOOT-BANNER-TIMEOUT-FIX-001/20261018T154359465Z/summary.json)へ保存した。

ユーザーの電源OFF／再接続報告とPC側COM3／COM6消失確認後、今回の「修正、実験」依頼を
一回のR18単一PARAM試験へ使用した。正本は
[`live summary.json`](runs/hil/R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001/LIVE-20261018T160030159Z-4b9d79fc/summary.json)、
SHA-256 `5C20D81F29C2B29DC2AD61562AD625F34F8F0FE0551B5BD8983FCA51D1CC2AD4`。
2026-10-19 01:00:31〜01:01:03 JSTに実行し、結果はPASS。
最終sealは同directoryの`final_seal.json`、SHA-256
`87F2E1601182EB0606137912226717C9602EC9F0EB8D108F31BF5998C2DD7F56`。

- raw 676 byte、正常MAVLink 18 frame、うちHeartbeat 16件。
- exact32-byte要求1回完了、`SERIAL1_BAUD=57`、param_count 932、index 65535、type 6、sys/comp 1/1の応答1件。
- 要求完了→応答5,297.170 ms、Heartbeat全区間最大2,113.785 ms、pump最大82.282 ms。
- parser／CRC／noise／partial／control leak及びPARAM_ERRORは0。対象重複0、応答後10,020.748 ms監視。
- 起動表示は266-byte `boot:0x2b`。cleanup 7/7 PASS、COM6 closed、競合process 0。
- ファーム／E220／actuator書込みは0。COM3は操作していない。一回限定許可は消費済み／再利用不可。

accepted R18 Vehicle製品版にはUSB診断がなく、R19専用JTAG recordも存在しない。
従ってCOM3無出力をVehicle障害と判定せず、旧診断版向けASCII queryを製品版へ流さない。
今回0 byteが再現しなかったことはR18の短時間双方向通信が成立した証拠だが、過去の0 byte原因の確定ではない。
全932件再取得・長時間・R19高速経路・932件30秒以内は今回未評価であり、R19 acceptance／DeploymentはNO-GO継続。

### 31.44 R19の40秒診断実機評価とGround ALIVE先頭32-byte停止（2026-10-19 JST）

全932件及びR19高速通信の「実験評価」依頼に対し、まず候補・試験手順を確認した。
旧eligible製品候補`20261011T140505553Z-18941c96`は公式verifierで
`Candidate HWCDC diagnostic-header hashes do not match their paths`となり書き込まなかった。
診断候補`20261012T151448091Z-3880c286`は整合性PASSで、outer模擬契約とツール整合性確認もPASSした。
R18全件runner契約は24/24 PASSだが、低速R18にも30秒条件を無条件適用し、停滞120秒・初回処理も別実装である。
従ってそのまま低速の完全性受入に用いず、R18とR19の評価目的を区別する必要がある。

ユーザーの全電源OFF／再接続報告とCOM3／COM6消失確認後、01:17:48〜01:21:08 JSTにR19診断を一回実施した。
live正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261018T161748244Z-13604e50/summary.json)、
SHA-256 `9C69EE82B602F2FD8D0DE2A82E1EC239AFEE718A6A83D4B24C199FBB0C2A9870`。
両roleのfresh active JTAG事前確認、candidate app-only installはPASSした。
PnP子summaryはPASSだがouter stepsにはFAIL／exit 1が残り、記録不整合として保持する。

40秒captureはVehicle COM3 2,709 byte／正常ALIVE 43件、Ground COM6 809 byte／正常ALIVE 10件＋
sys/comp 1/1のHeartbeat 7件＋末尾partial 32 byteだった。両roleともbad CRC／noise／bad lengthは0。
VehicleのPC最大service gapは323.752 msで100 ms基準を超過し、Groundは84.469 msだった。
Vehicleは39.354591秒までALIVEが続く一方、Groundの最終進捗は7.402500秒だった。

Ground raw offset 777の末尾は、next sequence 12の`R19A:G:L:0000000C:000`を含む63-byte診断frameの先頭32 byteである。
不足31 byteは約32.678秒の無進捗と追加500 ms取得後も届かなかった。
このframeはGround内部で生成するUSB診断であり、RF経由のPARAMデータではない。
停止区間はGroundのlocal診断→HWCDC→PC受信に絞られるが、FIFO／flushの具体的predicateは未確定である。

現在のJTAG特例読取りはsource-bound R19Fのexact terminal prefixだけを扱うため、今回は
`FAIL_PARSER_CORRUPTION / INVALID`でcause record読取り前に拒否された。
outer結果は`FAIL_CAPTURE_R18_RESTORED`。最後に両roleをaccepted R18へwrite／digest verify／再列挙付きで復旧した。
全child終了とCOM cleanupはPASS、`power_off_required=false`。復旧後の通信livenessは再測定していない。
独立監査でinstall 66/66、capture 67/67、rollback 58/58のmanifest・SHA一覧・各sealが一致した。
outer自身にはfinal sealがないため一括封印済みとは扱わない。

結果と次工程は
[`REPORT.md`](runs/validation/R18-R19-EXPERIMENT-READINESS-001/20261018T161203036Z/REPORT.md)及び
[`評価summary.json`](runs/validation/R18-R19-EXPERIMENT-READINESS-001/20261018T161203036Z/summary.json)へ保存した。
次はR19A exact partialの診断分類／cause読取り、dual-COM公平性、整合した製品候補の再生成を扱う。
今回の診断結果を全932件取得又は高速製品版の転送速度測定へ拡張せず、R19 acceptance／DeploymentはNO-GO継続とする。

### 31.45 R19A fail-only原因取得gate追加とHeartbeat USB公開失敗の実機特定（2026-10-19 JST）

前回のGround R19A terminal32/63を、通信成功へ昇格せずJTAG原因取得へ渡す別契約をtest-firstで追加した。
変更はcapture runner、outer、両契約試験の4 fileであり、firmware、UART、E220、TDD及びsealed candidateは変更していない。
変更前の両契約RED、変更後runner自己試験59/59（PS5.1／7）、実測raw再演と8変異拒否、outerの20証拠変異・
SHA再計算済み7 raw変異拒否及び全mock scenario（PS5.1）はPASSした。host CTestは310/310、内部集計は275 PASS／
expected XFAIL 2／unexpected FAIL 0。ArduinoはVehicle→Groundの順でPASSしたが、この新規compile binaryは実機へ書き込んでいない。
PS7 outerの既存`$PSHOME/powershell.exe`制限とtool-discovery scripts-tree pin不一致は修正・緩和せず、実機は標準PS5.1を使用した。

オフライン差分・証拠・構造化結果は
[`summary.json`](runs/validation/R19A-PARTIAL-CAUSE-GATE-001/20261018T165101454Z/summary.json)及び同directoryの
`changes.json`、`diffs/`、`cause_analysis.json`へ保存した。capture runner SHA-256は
`EAACD83917E77F8112CE0E75733625FBBB61C16CF1D04F73E2700C14E3DB591F`、outerは
`5281B96F5E8B3ECAD13A77D1DFC79424AD575858C3F182A12E4F0B9528AF932E`で、child pinも一致する。

ユーザーの追加実験依頼、安全6項目再確認、全電源OFF／再接続報告とPC側の両port／parent消失・再接続確認後、
今回の許可を1回のdiagnostic HILへ使用した。並列agent・監査・compileを終了させてから、前回と同じ診断候補
`20261012T151448091Z-3880c286`を使用し、02:12:18〜02:14:48 JSTに実行した。live正本は
[`summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261018T171157707Z-e0e2304d/summary.json)、
SHA-256 `5550ABAC4BFE177126FE7F030E03CAA53CE3BDF57814F50A39FCDFEB1C774900`である。

40秒captureでVehicleは2,646 byte／ALIVE 42件、Groundは441 byte／完全R19F 6件／先頭31 byte／末尾32 byteだった。
完全frameのbad CRCは両roleとも0。PC最大service gapはVehicle 254.079 ms（100 ms超過）、Ground 65.150 msであり、
Vehicle側の超過がGround停止を引き起こしたとまでは証明していない。

Ground R19F 6件はsequence3〜8で全て同じfirst-failure snapshotを保持する。
`source_line=3178`、起動後`5483 ms`、status `000100000000`、USB loss epoch `1`である。
exact candidateの3178行は`observe_ground_paced_heartbeat_commit()`の`TxResult::Rejected`停止に一致する。
従って最初の製品側異常は、21-byte Heartbeat全体をLocalEgressからHWCDC受理境界まで渡した後、USB公開完了を
確定できなかったことである。契約は106 ms（物理書込み6 ms＋USB完了確認100 ms）だが、
`transport_published && endpoint_ready && completed<=deadline`のどの項目がfalseだったかは未分離であり、
単純な106 ms超過が確定したとは扱わない。flush前期限到達の3130行及びpacer完了API失敗の3175行とは区別できる。

先頭31 byteは同snapshotの前sequence2のR19F後半31 byteと、再計算CRC `0xF5E5`（wire `E5 F5`）を含め31/31一致する。
sequence0〜255を照合して一致は2だけだった。ただし先頭32 byteは未観測で、sequence2全frameを実受信した証明ではない。
受信形は「seq2後半31 → 完全seq3〜8 → seq9前半32」と整合し、先頭31をRFのランダムnoiseと説明しない。
一方parser上はこの先頭31がnoiseとして残り、既存R19F gateの「末尾partial以外の異常なし」を満たさなかった。
今回のR19A専用gateの対象でもないため、JTAG内部record読取り前に停止した。active JTAG事前確認は両role PASSである。

seq9末尾31の未到着は、最初のHeartbeat公開失敗を報告する診断経路で発生した後続障害である。
最初の製品Heartbeatの106 ms契約と、診断frameの500 ms契約を混同しない。FIFO／ring／stash／host pickupの具体的
不成立条件はJTAG未取得のため未確定で、次は既知R19F先頭suffixをfail-only原因取得で厳密に扱う必要がある。

outer結果は`FAIL_CAPTURE_R18_RESTORED`。両roleのaccepted R18復旧はdigest verify及び再列挙付きでPASSし、全child終了と
COM cleanupもPASS、`power_off_required=false`。復旧後の通信liveness、全932件取得、30秒高速転送は今回未評価。
今回の1回許可は使用済みで追加実機試験はしていない。R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.46 R19F原因取得gate整備とGroundの31-byteソフトウェア送信待ちを実機特定（2026-10-19 JST）

「予定内容の試験」依頼に基づき、既知のR19F先頭31-byte suffix、同一snapshotの連続完全frame、次sequenceの先頭32-byte
prefixを厳密に再演し、通信FAILのままJTAG原因取得へ進めるhost側契約をtest-firstで追加した。欠けたbyteの補完、
noise／partial／CRC判定の緩和は行っていない。またreader-v3の正当なshort-packet完了（ZLP不要）をouterでも扱うよう、
独立RED→GREENと6不正変異拒否を追加した。変更はhost tool 2件と契約試験2件のみで、firmware、UART、E220、TDD及び
診断候補`20261012T151448091Z-3880c286`は未変更である。新規leading-suffix分岐はoffline実測raw再演で検証し、
今回liveは先頭noise 0の既存terminal-prefix分岐を通った。両者を混同しない。

capture契約はPS5.1／7、outer契約は標準PS5.1でPASS。PS7 outerの既存`$PSHOME/powershell.exe`制限は未変更。
host CTest 310/310、内部275 PASS／expected XFAIL 2／unexpected FAIL 0、Arduino Vehicle→GroundもPASSした。
新規compile binaryは書き込まず、封印済み診断候補を使用した。差分、RED／GREEN及び評価は
[`summary.json`](runs/validation/R19F-LEADING-SUFFIX-CAUSE-GATE-001/20261019T115302069Z/summary.json)、
同directoryの`changes.json`、`diffs/`、`cause_analysis.json`へ保存した。

安全6項目、全電源OFF／再接続とPC側消失を確認した。最初のpreflight
`20261019T121054126Z-8548819c`はUSB物理位置不一致で停止し、COM open、device open、flash、OpenOCD、JTAG clockは全てfalse。
同じserial-numberのVehicle／Groundが現在`1-4.2`／`1-4.4`にあるとOS記録で確認してselectorのみ訂正した。
これは実機試験未開始であり、別の実機試験回数へ数えない。並列agent／監査／compileを止めた後、許可された実機操作を
21:13:12〜21:15:45 JSTに1回実施した。正本は
[`live summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261019T121259028Z-36f5e6e0/summary.json)、
SHA-256 `2BC62C54AAABF4337A85F61A87D0954A9C91AFBF687AC242F25820C88317F8D2`。

40秒captureではVehicle 2,646 byte／完全ALIVE 42件、最後39.871170秒まで継続。Groundは347 byte＝完全R19F 5件×63＋
次frame先頭32 byteで、3.876711秒以降、追加tail取得終了40.516342秒まで約36.640秒進捗がなかった。
両roleの完全frame CRC／noiseは0、Ground partialは32 byte。PC最大service gapはVehicle 273.082 msで100 ms超過、
Ground 66.976 msである。serial writeは0で、今回RF上りコマンドや全932件の転送は実施していない。

今回は両roleの68-byte runtime-stageと112-byte endpoint-FIFO recordを各2回同一取得できた。
Groundのlast-committed診断状態は`ring=31 / stash=0 / FIFO writable=true / publish=pickup=15 / payload-in-flight=false`。
直近flush blockerは`SoftwarePending`のみで、FIFO write 15回、payload pickup 15回、zero write 0、bus reset 0、ZLP 0だった。
従って後続31-byte停止の待ち場所は**GroundのHWCDCソフトウェアring→空きFIFOへの転送再開境界**まで特定できた。
「31 byteがFIFO内でPCの引取りを待つ」「RF上で31 byteを失った」「不要ZLP待ちが再発した」とは、この記録は整合しない。
ただしring内容そのものはdumpしておらず、31 byteを末尾suffixへ対応付けるのは専用writerとframe会計による整合評価である。
累積FIFO 431 byteとPC capture 347 byteとの差84 byteについて、capture外で送った内容までは断定しない。

コード上の有力候補は、`writeTxChecked()`がenqueue前だけclean-idleを判定する間隙である。
先行32 byteがまだin-flightのためtask primeを予約しない→ISRが先行分のpickupと空ring処理を完了→残り31 byteをenqueue→
割込みenableだけで再primeしない、という順なら今回の状態を再現し得る。`flushTxComplete()`も割込みenableの反復のみである。
ただし実際の割込み順序は未記録であり、このraceを実機で直接証明したとは扱わない。
`last_interrupt_status=0`はmasked statusであり、raw IN_EMPTY=0やinterrupt enable=trueを意味しない。
次の修正ではenqueue前後の遷移を再現する失敗試験、epoch／排他を維持した再始動、raw／enabled割込み記録を検討する。

最初の製品Heartbeat失敗は別ラッチで、R19Fの`source_line=3178 / uptime=4911 ms / status=000100000000`。
Groundの診断境界flush失敗は`5412 ms`で、その501 ms後である。最新／累積FIFO記録から、最初のHeartbeatの
`transport_published / endpoint_ready / completed<=deadline`のどれがfalseだったかは、なお確定できない。
VehicleのJTAG時`publish=105 / pickup=104 / ring=31 / FIFO not writable`はCOM close後の正常backpressureが混入し得るため、
capture中にGroundと同じ停止が続いた証拠とはしない。

outerの名称は`FAIL_STAGE_READ_R18_RESTORED`だが、実際の両stage reader resultはPASS、`.proven=true`である。
USB完了未証明を同じ最終FAILへ合流させる分類上の問題で、JTAG取得失敗と説明しない。PnP childのPASSとouter stepのFAIL／exit 1は
生の結果として保持する。ただし後続のsource確認で、このPnP-only gateは意図的にexit 1とし、driver確認だけでfirmware installを許可しない設計と判明した。PnP child自体の故障とは扱わない。独立監査はinstall 66/66、capture 61/61、rollback 58/58のmanifest・SHA・seal一致を確認した。
stage directoryはseal未生成仕様で、二重binary読取りSHAと親参照を確認した。両CPU0／CPU1のrunning、shutdown、COM cleanup 5/5、
全8子処理終了も証明された。両機をaccepted R18へ初回digest verify付きで復旧し、`power_off_required=false`である。
復旧後通信liveness、全932件、30秒転送及びHeartbeat 2,500 ms受入は今回未評価。
一回限定許可は消費済みで追加実機試験はしていない。R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.47 busy→idle送信再開と初回Heartbeat失敗記録のtest-first修正（2026-10-19 JST、offline-only）

ユーザーの「その方向で進めます」に基づき、次の実機試験前のオフライン修正を実施した。COM open、JTAG、機器への書込み、
RF通信及び電源操作は一切行っていない。既存sealed候補3880及びaccepted R18 imageは変更していない。
変更前sourceのsnapshot、RED／GREEN、差分、検証結果は
[`summary.json`](runs/validation/R19-HWCDC-BUSY-IDLE-RESTART-OFFLINE-001/20261019T125700531Z/summary.json)、
同directoryの`before/`、`after/`、`changes.json`、`diffs/`へ保存する。

診断macro限定の`HWCDC::writeTxChecked()`で、enqueue後にepoch／reset、既存queue／stash、payload世代、FIFO、fence／debug writerを
同じTX mux下で再判定する。新たな入力だけが残るidle境界を確認できた場合は、古いIN_EMPTYをmask／clearして予約し、既存の
checked task-prime処理を再利用する。これにより、入口ではbusyだったがenqueue前にpickup／空ringのISR処理が完了する経路を扱う。
さらにISRのpickup区間とdrain区間の間にtaskが新payloadを公開した場合、古いISRのdrain／空queue処理及びfallback cleanupが
新しい割込みを消去・無効化しないよう再確認を追加した。zero write、partial write、reset quarantine、同一epoch、順序及び
一回限りの公開条件を維持し、spinlockを保持したまま`xRingbufferSend()`を呼ばない。macro-offの通常経路は変更していない。

既存68-byte runtime／112-byte FIFO recordとR19F wireは不変のまま、独立128-byte recordを二つ追加した。
`vc_lora_r19_hwcdc_restart_diagnostic_record`は初回idle-pending条件のraw割込み／enable mask／queue／世代を保持し、最新の再開結果も記録する。
`vc_lora_r19_ground_usb_commit_record`は初回Heartbeat失敗時の3述語の「観測済み」と真偽、開始／flush開始／完了／期限の64-bit時刻、
token、epoch、受理byte会計を保存する。flush後の接続再評価でcommitがretireする場合も、既知のflush結果を失わない。
後続の診断で初回記録を上書きしない。新classは既存headerに同居させ、依存header13件の閉包を維持した。
rawとenableは同じ排他区間の隣接観測であり、非同期hardwareの全bitを完全な同一瞬間に取得したとは表現しない。
restart条件の初回記録と、Heartbeat失敗の初回記録が同じ出来事であるとも決めつけない。

busy→idle、古いISR後段、cleanupの3種類を修正前にRED再現し、修正後はtask-prime 60 checks／0 failures。
epoch/reset、quarantine、stash、旧queue、FIFO非writable、payload待ち、fence／abort／debug等の不安全条件も検証した。
FIFO／restart recordは175 checks、Heartbeat record17、source contract8、bridge7ケース計68、旧runtime ABI36がPASS。
新recordのoffline decoderはPS5.1／7各58/58、既存readerは各117/117 PASSである。
全host CTestは320/320 PASS（246.99秒）、従来内部集計は275 PASS／expected XFAIL2／unexpected FAIL0だった。

加えて、変更前／変更後の`writeTxChecked()`本体を無編集で抽出し、host用の最小stubと組み合わせて直接実行した。
同じ「先行32-byte pickup＋空ring ISR処理をenqueue前に注入」の条件で、変更前はaccepted31／ring31／FIFO0／host32となり
期待どおりFAIL、変更後はring0／FIFO31となり、次のpickup後にexact63 byteを重複なく受信してPASSした。
正本は同評価directoryの`busy_idle_actual_function/summary.json`。抽出関数／sourceのSHAも保存している。
これはwriter本体の直接RED→GREENであり、外部pickup／ISRのタイミング自体はstub注入である。

SDKは既知の旧3-file SHA一式だけを認識して更新し、旧ファイルを`installed_sdk_before/`へ保存した。
不明／混在SDKを上書きする判定は緩和していない。通常ArduinoはVehicle→Groundの順にPASSし、Flash／RAMは
Vehicle390,613／101,920 byte、Ground360,849／65,512 byte。manifest SHA-256は
`D6846B24E130CD69DE6D48ED634DD64ACD53909FDB75768E2D66F387B71BDFFD`。
修正を有効にする診断macro付きの別ビルドもVehicle→Groundの順でPASSした。Flash／RAMはVehicle440,801／106,712 byte、
Ground414,029／70,360 byte。両roleのELFに4種類のJTAG symbolが68／112／128／128 byte、4-byte alignmentで存在することを
offline nmで確認した。標準manifest／source snapshotも保持されている。正本は同評価directoryの`diagnostic_compile.summary.json`である。
これらはコンパイル確認用の生成物であり、新しい封印candidateの公開や機器への書込みは行っていない。

新128-byte recordのdecoderは明示的offline-only指定に限定し、Execute／Preflight／native実行との併用を拒否する。
実機ELFからの新symbol発見、同一halt中の追加読取り、candidate manifest及びouterへの接続は未実装である。
reader変更後のSHAは`7444FE9D9D010232F80CE8CD1E1551F5FFC9BE84B5165A6C8D8DCE7C2E3BCB61`だが、outerの旧pinは
意図的に更新しておらず、不一致時は実機開始前に停止する。次回はこれらの取得手順を整備し、新たな封印候補を生成・検証してから
別の一回限定実機許可を得る必要がある。旧3880を今回の修正版とみなして再利用しない。
追加recordによりリンク後のRAMアドレスも変わるため、旧runtimeアドレスを流用せず、新ELFからsymbolを確定して厳密に結び付ける。
今回のオフライン修正だけで過去の実機interleavingの発生を証明したり、31-byte停止の実機解消、932件30秒、Heartbeat最大2,500 msを
合格扱いにしたりしない。R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.48 新記録のJTAG取得統合・新診断候補の生成と独立検証（2026-10-19 JST、offline-only）

ユーザーの「この評価進めます」に基づき、Section 31.47で追加した記録を実機で取得できるようにするための準備を完了した。
COM open、active JTAG、CPU halt、機器への書込み、RF通信、電源操作は一切行っていない。
オフライン変更、RED／GREEN、before／after、差分及び結果は
[`summary.json`](runs/validation/R19-EXTENDED-JTAG-INTEGRATION-OFFLINE-001/20261019T133627041Z/summary.json)
と同directoryの`candidate/`、`reader/`、`outer/`、`changes.json`、`diffs/`を正本とする。

reader-v4は、各roleの同一SMP halt内で次の4記録を各2回取得し、8 rawを保存する。両roleの合計は16 rawであり、
両機を同時にhaltする設計ではない。既存68／112-byte ABIは維持した。

| 記録 | byte | Vehicle | Ground | 判別する内容 |
|---|---:|---|---|---|
| runtime-stage | 68 | `0x3fcab500` | `0x3fca2750` | 起動・実行段階と最初の失敗 |
| endpoint-FIFO | 112 | `0x3fcab8f4` | `0x3fca2af8` | queue、FIFO、世代、flushの最終診断状態 |
| HWCDC restart | 128 | `0x3fcab874` | `0x3fca2a78` | 初回idle-pending条件と送信再開の結果 |
| Ground USB commit | 128 | `0x3fcab480` | `0x3fca26d0` | 初回Heartbeat失敗時の3述語、時刻、byte会計 |

これらは新候補のsealed ELFから確定したアドレスであり、旧3880のruntimeアドレスを流用しない。
manifest／handoff／sealに4 symbolの名前・サイズ・整列・非重複、ELF／MAP／application SHAを結び付け、
独立nmでも両roleを再確認した。部分的な拡張宣言、v4宣言をv3へ落とすdowngrade、型・大小文字・hash鎖の不一致を拒否する。
旧v3互換は拡張宣言と拡張symbolが完全に存在しない候補に限る。新reader契約はPS5.1／7とも47/47、
旧v3契約117/117、旧拡張offline decoderは両環境58/58 PASSである。

outerも8 rawのSHA・サイズ・順序・2回同一性を独立に検証し、USB完了分類、runtime失敗理由、初回Heartbeat述語を再計算する。
reported文字列／booleanを原データと食い違うまま信用せず、文字列`"false"`を真のbooleanとして扱うことも拒否する。
記録取得PASSと、記録時点のUSB完了未証明を分離した。後者は`FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`、
初回Heartbeat失敗ラッチは別分類で保持し、通信正常又は製品受入PASSを意味しない。
JTAG記録はCOM close後であり、最後のFIFO状態だけからcapture中の継続停止を断定しない。
記録未ラッチも「対象eventを未観測」の意味で、機能の未動作を必ずしも意味しない。
PnP-only gateの意図されたexit 1は変更せず、driver確認だけでは書込みを許可しない。
旧3880の実測raw回帰は旧ID／manifest／sourceに固定し、新候補の証拠として付け替えていない。

最初の全host試験は320/321で、flash toolのverifier／common SHA pinが旧版のまま拒否された。
REDを保存し、確認済み2 hashだけを更新して既存試験を変更せず合格させた。
その後の全hostは**321/321 PASS**（307.91秒）、内部集計は275 PASS／expected XFAIL 2／unexpected FAIL 0。
最終候補ID・latest SHA・新runtimeアドレス・reader／flash子tool SHAをouterへ再pinし、正式なPS5.1契約試験もPASSした。
25模擬シナリオ、8 rawの偽装拒否、最後に追加したhalt／process終了未証明の否定試験を含む。

通常ArduinoをVehicle→Groundの順に再ビルドしてPASSした。Flash／RAMはVehicle390,613／101,920 byte、
Ground360,849／65,512 byte。標準manifest SHAは
`58EF12477BA98E99373F4957E450E8E7D47DB36711CB5463C4CD48BCAE87ED1B`である。
その後に診断macro付きの新候補をVehicle→Groundの順でビルドした。Flash／RAMはVehicle440,801／106,712 byte、
Ground414,029／70,360 byte。初回のbuild呼出しはRepoRoot引数の既定値解決で、候補生成前に停止した。
ログを保存し、`-RepoRoot E:\VESC\TRIAL_LOG\Loreley3_System\06_vc_lora_bridge`を明示して正常完了した。

新候補は`runs/candidates/R19-RUNTIME-FAIL-DIAGNOSTIC-CANDIDATE-BUILD-001/20261019T141020427Z-ad4dbc5b/`。
latest SHAは`DC5DCCF0A270F59F55025EB049C279432757D630278D48599F48E6C63FED7320`、
manifest SHAは`A52177ED199DB27B0EB6B757AC524F45B24974B5F85306308F10A200D125AC62`、
seal SHAは`F5048D9AD9971F94382C7C62F77C87242C39985C693BB3DF18E63964391029B7`。
app SHAはVehicle `32930EA1E6B0B781BBB7A2E7742DD4BBD0F807FCB992356934FD4E73BC7F676C`、
Ground `53A2BAE69A02B1BB3E8E2E8859B373BB7094CCDB43E34B6D9C57306A78D114A1`。
候補verifierと実readerの`Assert-ArtifactBinding`を、PS5.1／7で実ELF・実nmに対して独立実行し、両role PASSを確認した。
OpenOCD／nm／設定／scripts treeの読取り専用tool-discoveryもPASSだが、active JTAG接続の今回の証明ではない。

旧3880のinventory142件、manifest、sealは不変で、accepted R18の両app size／SHAも保持されている。
新候補生成中に通常版manifest／artifactsを変えていないことも確認した。UART、E220プロファイル、TDD設定、配線は未変更。
次は**この新候補を指定した新たな一回限定許可と安全6項目再確認後**に、application-only書込み（Vehicle→Ground）→
40秒dual-COM→両role全4記録読取り→accepted R18復旧を行う段階である。今回のオフライン評価を実機試験の許可として再利用しない。
実機の31-byte停止解消、過去の実割込み順序、全932件30秒、Heartbeat最大2,500 ms以下及び全error 0は未確認で、
R19 acceptance／Deploymentは**NO-GO継続**とする。

### 31.49 新候補の1回実機評価：診断連続停止は未再現、初回HeartbeatのUSB完了失敗を分離（2026-10-19 JST）

ユーザーの実験依頼、一回限定許可、安全6項目再確認、全電源OFF／再接続報告を受けて実施した。
OSでもCOM3／COM6と両XIAOの消失を確認後、再接続時の親serial及びUSB位置を確認した。
Vehicleは`COM3 / 90:70:69:11:81:A4 / 1-4.2`、Groundは`COM6 / 1C:DB:D4:5A:83:80 / 1-4.4`。
候補とsource／SDK／復旧binaryの読取り専用独立監査を完了し、全並列agent・監査・compileを停止してから実機を操作した。
開始状態の証拠は`runs/preflight/R19-EXTENDED-HIL-START-STATE-001/20261019T143504262Z/`、
実機前独立監査は`runs/preflight/R19-EXTENDED-HIL-ARTIFACT-AUDIT-001/20261019T143538085Z/summary.json`である。

最初の呼出し`20261019T143715415Z-bd677506`は、wrapperが保存先を先に作成したため上書き防止で停止した。
toolの出力先初期化で停止しており、子tool起動、COM open、JTAG、書込みは0。
その証拠を保持し、まだ存在しない保存先へ指定を修正した後、許可された実機workflowを**1回だけ**実施した。
実機は23:37:57〜23:40:39 JST。新候補のapplication-only Vehicle→Ground書込み、40秒dual-COM、
両roleの全4記録読取り、accepted R18復旧を完走した。正本は
[`live summary.json`](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261019T143756436Z-96e75936/summary.json)、
SHA-256 `67C9515BD568B7860ADC479A24289923E85B46FB69D1E46967E4222A91F5BE39`。
評価、原記録検証、因果分析、差分及び独立監査は
[`evaluation summary.json`](runs/validation/R19-EXTENDED-LIVE-EVALUATION-001/20261019T144100000Z/summary.json)
と同directoryの`causal/`、`integrity/`へ保存した。

| 40秒診断取得 | Vehicle | Ground |
|---|---:|---:|
| 受信byte | 2,646 | 2,646 |
| 完全診断frame | ALIVE 42 | R19F 42 |
| 最後のframe到着 | 39.799544 s | 39.822791 s |
| 最大診断frame間隔 | 1,049.514 ms | 1,032.417 ms |
| CRC／noise／partial | 0／0／0 | 0／0／0 |
| PC最大service gap | 275.579 ms | 65.890 ms |

Groundのsequenceは1〜42で継続し、前回の347 byte＝完全5 frame＋次frame先頭32 byteという長時間停止は今回再現しなかった。
ただしこれは**ローカルUSB診断通信**の改善であり、製品テレメトリ／RFリンクの連続性又はHeartbeat SLAを合格させたものではない。
本runのserial writeは0、非診断完全frameも0であり、上り要求、全932件、30秒転送は実施していない。
VehicleのPC service gapは100 ms基準を175.579 ms超過した。診断取得自体は成立したが、この時間品質FAILを除外又は緩和していない。

新記録は各role8 raw、合計16 rawを安定取得した。Groundの初回製品Heartbeat記録は次のとおり。

| 条件 | 記録値 |
|---|---|
| 期待／受理 | 21／21 byte、commit goal＝bytes committed＝21 |
| commit開始／flush開始 | 起動後5,229／5,229 ms |
| 完了観測／絶対期限 | 5,335／5,335 ms |
| 経過／残りbudget | 106／106 ms |
| `transport_published` | **false** |
| `endpoint_ready` | true |
| `completed<=deadline` | true（記録のms分解能） |
| epoch | 1→1 |
| ラッチ | PublicationRejected、token1、source3243、observed7／true6 |

従って以前未分離だった3条件のうち、不成立は`Serial.flushTxComplete()`を通るtransport完了条件である。
「21 byteを受理できなかった」「接続述語が偽」「外側の絶対期限を超過した」とは今回の記録は整合しない。
R19Fのproduct fail-closed位置は新source3281／起動後5,335 msに一致する。
別の診断runtime-stageは`GroundBoundaryFlushFailed / 5,836 ms`を保持し、501 ms後の別事象である。
ただし最初のflush失敗瞬間のFIFO／queue／lock／pickup／内部return理由は、この記録には含まれていない。

Ground restart記録は`PostEnqueueIdleTransition / ordinal48 / ring31 / stash0 / FIFO writable / publish=pickup=78`を初回ラッチした。
これにより修正対象のbusy→idle enqueue窓へ実機が到達したことを確認できた。
一方、最新restartは別event62の`EntryCleanIdle / Published32 / publish98 / pickup97`であり、
event48直後の31 byte送出結果を直接保存しているわけではない。初回Heartbeat失敗との同一因果や過去のISR実行順序も証明しない。

両roleの最新FIFOはCOM close後に取得され、ring31があってもFIFO非空／世代1つ先／payload in-flightである。
前回の「FIFO空き・世代等値・payloadなしでring31だけが残る停止」とは状態が違う。
後から閉じたPC側の正常backpressureが混入し得るため、この最終snapshotだけをcapture中の恒久停止と説明しない。
またverify hard-reset→再列挙→COM openの時系列から、初回Heartbeat失敗がPCのCOM open前に発生した可能性がある。
ただし`esp_timer`のUTC原点は記録しておらず、ファイル時刻には丸めもあるため、現証拠だけでは確定しない。
`endpoint_ready=true`もWindows側consumerが開いていたことの証明ではない。

outerは`FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`。
record acquisitionはPASSだが、最終USB完了未証明、初回製品Heartbeat失敗、PC service SLA未達により通信評価はFAILである。
独立監査259項目は不一致0で、install66／capture98／rollback58のinventory・SHA・seal、
16 rawのsize／SHA／二重同一性、両CPU0／CPU1 runningとshutdown、COM cleanup5/5、全8子処理終了を確認した。
両機ともaccepted R18へapplication digest照合・再列挙付きで復旧し、`power_off_required=false`。
復旧後の通信livenessは別途測定していない。今回の一回限定許可は使用済みで、追加の実機試験やfirmware修正はしていない。

次のオフライン調査対象は、最初の`flushTxComplete=false`の内部理由と、ホストopen前／後の起動待ち・backpressureの扱いである。
期限値を単に延ばしたり、観測済みfalseを成功へ変更したりしない。
全932件30秒、製品Heartbeat最大2,500 ms以下、全error0及びDeploymentは**NO-GO継続**とする。

### 31.50 初回USB失敗の固定記録・PC読取り時系列・誤差区間判定のオフライン修正評価（2026-10-20 JST）

ユーザー指定の3項目をtest-firstで修正し、合成入力と既存回帰試験で定量評価した。
**本節は実機測定ではない。** COM open／write、JTAG、firmware書込み、電源操作は行っていない。
accepted R18の保存BINは不変で、機器上の通信livenessを今回再確認したものでもない。
正本は`runs/validation/R19-FIRST-FAIL-INSTRUMENTATION-OFFLINE-001/20261020T100323294Z/`の
`summary.json`、各subdirectoryのRED／GREENログ、変更前後snapshot及び差分である。

#### 初回失敗を後続診断で上書きしない

診断macro限定で`vc_lora_r19_first_usb_failure_record`を追加した。固定384 byte／96 wordで、
role、build fingerprint、bootごとの128-bit識別子と、最初の製品Heartbeat失敗を保持する。
初回失敗部のword 20〜61は、後続flush、診断frame、時刻同期で上書きしない。
既存68／112／128／128-byte記録のABIは変更していない。

SDKには通常の2引数APIとは別に`flushTxCompleteDiagnostic()`を設けた。
返却理由をSuccess／NullRing／NullLock／LockTimeout／LoopTimeout／EpochAbortへ分離し、
token、attempt、budget、epoch、ring／stash待ち量、FIFO状態、publish／pickup世代、
interrupt／blocker mask及びsnapshot所要時間を、固定96-byte PODで呼出し元へ返す。
API未呼出し、snapshot未取得、観測済みの0を区別し、「未観測の0＝正常」とは扱わない。
wrapperではSDKのraw return、endpoint、既存deadline条件を別々に保存する。
従来の106 ms契約、ms分解能の期限比較、失敗時の停止条件は緩和していない。

これは**失敗判定直近の観測**であり、非同期USBハードウェア全体を凍結した同時snapshotではない。
固定記録の時刻は`esp_timer_get_time()`のµs、SDK内の32-bit ms／µs観測は別fieldとし、
物理障害の発生時刻と失敗を検出した時刻を同一視しない。
診断呼出し1回につきterminal snapshotは最大1回、追加のµs時刻標本は最大2回である。
追加処理の実機所要時間は**未測定**であり、無負荷／影響0とは主張しない。

#### PCのOpenとReadを別の記録にする

最初のCOM openより前に共通の単調増加時計を開始し、両roleを同じQPC領域で記録する。
Open開始／返却、読取りloop準備、各Read開始／返却、最初の正のRead、frame完成、
例外及びCloseを分離した。UTCやファイル更新時刻を前後関係の判定に使わない。
既存のcapture開始時点、startup drainのbyte保存、100 ms service基準、serial write 0は維持した。

traceは8,192 event×6 Int64＝393,216 byteの固定PC側領域で、取得中のファイル出力は行わず、
COM close後にまとめて保存する。overflowは`INCOMPLETE`であり、完全な観測へ昇格しない。
`READ_LOOP_ARMED`はアプリケーション上の準備境界で、保留中のReadやUSB host pollingの証明ではない。
`FIRST_POSITIVE_READ`もアプリケーションがbyteを受け取った返却標本で、物理USB到着時刻ではない。

#### 誤差区間が分離できる場合だけ前後を判定する

診断専用のnonce付き28-byte MAVLink2 TIMESYNC request／reply codecと、Groundのローカル応答経路を追加した。
予約済みsource／nonce、完全frame、CRCを検証し、当該診断要求はRF／Pixhawkへ転送しない。
返信は製品／診断frameのclean boundaryだけで始め、部分書込みのprefixを再送せず、
同じepochと有界deadlineを守る。通常製品版では無効である。

PC側はrequest直前〜reply受信直後の往復区間、device時刻の量子化、保証付き時計誤差を合成し、
整数有理演算と外向き丸めで失敗観測時刻の区間を求める。
COM Open区間の完全な前なら`PRE_PC_OPEN`、完全な後なら`POST_PC_OPEN`、接触／重なりは`UNKNOWN`。
読取りloop準備と最初の正のReadはそれぞれ独立した比較結果とし、Open後をRead開始後と読み替えない。
role／candidate／session／boot／nonce／QPCが不一致、時刻の順序不正、宣言済みtraceの欠落・overflow、
reset／sleep／halt等の連続性未証明、保証付き誤差上限なしの場合も`UNKNOWN`とする。

| オフライン評価 | 結果 | 証明範囲 |
|---|---:|---|
| 時刻区間の合成条件 | 4,141＋369＝4,510条件、誤ったPRE／POST 0 | 評価した境界・誤差率の条件内 |
| 時計比較の契約 | PS5.1／PS7とも45/45 PASS | 不正順序、別boot、境界接触、整数精度、Read別判定等 |
| PC traceの契約 | 両環境6/6 PASS | 有界記録、overflow、既存時刻との分離 |
| SDK実メソッド抽出fixture | 16 case／177 check、FAIL 0 | 通常APIとの返却・待機動作の同等性 |
| 初回記録／純粋decoder | C++30＋decoder29 check、FAIL 0 | 初回固定、旧ABI維持、破損／不正値拒否 |
| 時刻同期codec | 521 check、FAIL 0 | CRC、namespace、nonce、時刻範囲等 |
| bridge統合fixture | 5/5 scenario PASS | transport／期限前／endpoint／wrapper遅延／部分返信 |
| 全host回帰 | 333/333 PASS、172.74秒 | 内部集計275 PASS／expected XFAIL 2／unexpected FAIL 0 |

4,510条件は同じ模擬入力を両PowerShellで確認したもので、独立した実機4,510試行ではない。
誤判定0から、未知の実機条件での誤判定確率0や通信回復を推定しない。
例として**保証された50 ppm・加算誤差10 µs・時刻量子化1 µsを仮定した合成条件**では、
RTT 1 msの時刻区間幅は1.290 ms、RTT 10 msでは10.290 msとなる。
RTT 500 msの同条件はOpen区間へ重なり`UNKNOWN`となる。
これらの誤差上限やRTTを今回実機で測定・保証したわけではない。

通常版／診断版のArduinoをそれぞれVehicle→Groundの順にビルドし、4/4 PASSした。
Flash／RAMは以下のとおり。増分はSection 31.48の同じ設定によるビルドとの比較である。

| ビルド | Flash byte（増分） | RAM byte（増分） |
|---|---:|---:|
| 通常Vehicle | 390,613（0） | 101,920（0） |
| 通常Ground | 360,849（0） | 65,512（0） |
| 診断Vehicle | 441,117（+316） | 107,096（+384） |
| 診断Ground | 419,389（+5,360） | 71,552（+1,192） |

初回記録単体は384 byteだが、Groundの総増分はSDK呼出し記録やローカル時刻返信処理等も含み1,192 byteである。
診断版には新記録counterの`volatile ++`に関する非推奨警告が各1件、通常Groundには既存の未使用変数警告が1件あり、ビルドエラーは0だった。
最終ビルド結果は本節の`compile.summary.json`、全hostの最終結果は`summary.json`と対応ログを参照する。
コンパイル用のローカルArduino SDKは、完全一致する直前版3ファイルをバックアップ後、
確認済みinstallerで新しい診断APIを含む版へ更新した。これはマイコンへの書込みではない。

全hostの途中失敗ログも保存した。旧common SHA pinと厳密なsetupソース境界の不一致を修正し、
並行開発中の新しい整数演算ガードのREDを保持した。
別の1回は既存reader試験のPowerShell7がCLR内部エラー`0x80131506`で終了したが、
同じsourceの単独再試験はPS7／PS5.1とも47/47 PASSで再現しなかった。
原因が判明したとは扱わず、失敗の除外や試験基準の緩和はしていない。

**残作業**は新384-byte記録のactive JTAG reader／candidate manifest／outerへの厳密な結合、
PCでnonce要求を実送信して同じbootの記録へ結び付けるworkflow、保証できる時計誤差上限の設定である。
新decoderは現時点でoffline fixture読取り専用、通常capture runnerも読取専用のままであり、
新候補の生成・公開、実機での記録取得・前後判定は行っていない。
従って**「PC受信準備前の失敗」か「受信開始後のUSB内部停止」かは依然未確定**である。
次の実機試験は上記の取得統合と独立検証を終え、新たな一回限定許可と安全条件再確認を受けてから行う。
全932件30秒、Heartbeat最大2,500 ms以下、全error0及びDeploymentは未評価／NO-GO継続とする。

### 31.51 初回USB失敗記録の実機取得手順へのオフライン統合（2026-10-20 JST）

Section 31.50の新384-byte記録を、候補ファイルの照合、JTAG取得、試験全体の独立検証へ統合した。
今回の範囲は**実機取得ツールの準備とオフライン評価**である。COM open／write、active JTAG接続、
マイコンへの書込み、電源操作は行っていない。通信設定・ファームウェア本体・ローカルSDKも変更していない。
評価記録は`runs/validation/R19-FIRST-FAIL-LIVE-ACQUISITION-INTEGRATION-OFFLINE-001/20261020T121141002Z/`の
`summary.json`、変更前後snapshot、RED／GREENログ及び独立監査である。

#### 候補と読取り処理の対応

新候補はreader schema `vc-lora-r19-runtime-stage-jtag-read-v5`、
拡張記録schema `vc-lora-r19-usb-extended-diagnostics-v2`を使用する。
新記録のdecoderをmanifest／handoff／sealへ同じSHAで宣言し、候補内へ封印コピーを保存する。
取得時は正本・封印コピー・source snapshotとの一致を検証し、検証した同一のbyte列だけを読み込む。
古いv3／v4候補の互換性は維持し、混在・不完全な宣言・宣言外の追加記録は拒否する。

ELFとMAP、application BIN、role、候補ID、書込み証拠の対応を確認した上で、
同じCPU停止区間に以下の順序を2回読み取る。全CPUの復帰確認と終了処理の証明は従来どおり必須である。

| 順序 | 診断記録 | 1回のbyte数 |
|---|---|---:|
| 1 | runtime stage | 68 |
| 2 | Endpoint FIFO | 112 |
| 3 | HWCDC restart | 128 |
| 4 | Ground USB commit | 128 |
| 5 | 初回USB失敗 | 384 |

1 roleあたり5種類×2回＝10 raw、両roleで20 raw・記録本体合計3,280 byteを検証する。
これは診断記録の大きさであり、JTAGプロトコルを含む転送量や取得時間の実測ではない。
ファイル名・順序・サイズ・SHA・2回の内容一致・role・boot・既知のABI・予約fieldを検証する。
記録中のbuild fingerprintは診断ABI世代の識別値であり、候補固有のhashの代用にはしない。
候補固有の同一性は封印したELF／BIN等のSHAで別途結合する。

outerは子readerの表示値だけに依存せず、全rawを再検証し、384-byteを独立に解析する。
SDKを呼んでいない状態・失敗記録なし・実際のfalseを区別し、SDKの終了理由と待ち状態を結果へ出す。
**記録取得PASSは通信PASSではない。** 新記録で製品Heartbeat失敗を観測した場合は、旧記録に失敗がなくても
通信評価をPASSへ変更しない。

#### オフライン評価

| 評価 | 結果 | 範囲 |
|---|---:|---|
| 新readerの取得・拒否条件 | PS5.1／PS7とも87/87 PASS | 10 raw、ABI、hash、型、復帰、サイズ欄なしsymbol等 |
| outerの独立解析 | 両環境50/50 PASS | raw改変、順序、候補・role、整数精度、未観測値等 |
| 旧readerの互換回帰 | 両環境117/117及び58/58 PASS | 旧ABI／旧fixtureの継続 |
| 新候補の独立検証 | PS5.1／PS7ともPASS | 実ELFの10 symbol、147 file、封印・decoder・SDK一致 |
| Arduino | 通常2＋診断2＝4/4 PASS | Vehicle→Groundの順。書込みなし |
| 全host最終回帰 | 335/335 PASS、350.41秒 | 内部集計275 PASS／expected XFAIL 2／unexpected FAIL 0 |

候補のmetadata拒否試験は32件、ELF拒否試験15件、handoff／seal改変8件、decoder依存改変4件を追加した。
独立監査の1,207照合及びELF／NMの74チェックは、ファイルとfieldに対する検査数であり実機試行数ではない。
通常Groundの既存未使用変数警告1件、診断版の`volatile ++`警告各1件は残るが、ビルドエラーは0である。

途中の全host回帰は2回とも334/335だった。1回目は試験中の旧アドレス期待値2か所、
2回目は新しく登録したcanonical outer試験がPS7からWindows PowerShell専用launcherを取り込んだことが原因だった。
期待値を封印済みMAPの実値へ更新し、この試験だけ実機outerと同じWindows PowerShellへ登録した。
全ての検査を保持し、通常launcher本体は変更していない。
拡張した候補fixtureのprocess待ち時間は負荷下129.09／164.34秒を受け120→300秒としたが、
これはオフライン試験の実行時間枠である。USBの106 ms契約、40秒capture、100 ms公平性及びHeartbeat 2,500 ms基準は不変である。

#### 診断候補と次の確認

診断候補は`20261020T123447347Z-b414028b`で、通常製品版ではなく受入／Deployment資格はない。
diagnostic latestのSHAは`7B9E24D307963177D3489627AB305023B8A31744B5008FD36210590D60F4DA41`。
封印済みMAPのruntime stageはVehicle `0x3fcab680`、Ground `0x3fca2bf8`、
新384-byte記録はVehicle `0x3fcab480`、Ground `0x3fca29f8`である。
outerの子処理hash・候補ID・latest SHA・アドレスをこの候補へ厳密に固定した。
accepted R18の8保存ファイルと前候補の封印済み148ファイルは変更していない。

通常のdual-COM captureは**読取専用・serial write 0のまま**である。
nonce付き時刻同期を実送信するworkflowと、連続した同一bootの時計を保証付き誤差幅で対応付ける工程は別の残作業である。
従って今回の統合だけで「PC受信準備前の失敗」又は「受信開始後のUSB内部停止」とは判定せず、
必要な同期証拠がない場合のPC時刻関係は`UNKNOWN`とする。

次の実機工程には新たな一回限定許可と安全条件再確認が必要である。
診断候補の書込み→40秒dual-COM→両roleの20 raw取得・独立照合→accepted R18復旧を評価し、
まず新記録の取得と初回失敗の終了理由を確認する。全932件30秒、Heartbeat最大2,500 ms以下、
全error0及び製品Deploymentは引き続き未証明／NO-GOである。

### 31.52 初回USB失敗記録の実機取得と106 msタイムアウトの確認（2026-10-20 JST）

安全条件6項目と全電源5秒以上OFFを再確認後、候補 `20261020T123447347Z-b414028b` を1回評価した。
PC側でも両XIAOの消失・再列挙を確認し、今回の接続はVehicle `COM3 / 1-4.2`、Ground `COM6 / 1-4.4`だった。
実行前の候補・decoder・ツール・sourceの照合を終え、並列監査を停止してから、
JTAG事前確認→application-only書込み→40秒dual-COM→両roleの内部記録読取り→accepted R18復旧を実施した。
UART／TDD／E220設定とファームウェアsourceは変更していない。

実機runは`runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261020T141509509Z-0e07837f/`、
事後評価は`runs/validation/R19-FIRST-FAIL-ACQUISITION-HIL-REVIEW-001/20261020T141509509Z-0e07837f/`である。
開始／終了はUTC `14:15:11.9498335`／`14:17:56.6885587`、日本時間23時15分〜23時17分。

#### 記録取得は成功 通信評価は不合格

| 40秒測定 | Vehicle COM3 | Ground COM6 |
|---|---:|---:|
| 受信byte | 2,646 | 2,646 |
| 完全な診断frame | ALIVE 42 | R19F 42 |
| CRC異常／noise／partial | 各0 | 各0 |
| PC処理の最大service gap | 263.398 ms | 79.736 ms |
| service gap基準100 ms | FAIL | PASS |

合計84 frameは各XIAOが生成したUSB診断であり、Pixhawkからの通常下りMAVLinkや上り要求の成功を示さない。
通常の完全frameは0件、serial writeは0回である。旧31-byte診断停止は今回再現しなかったが、
製品Heartbeatの完了失敗を報告するGround R19Fが42回届いているため、通信合格にはならない。
PC traceは262 event・drop 0で取得したが、Vehicleのservice基準は不合格である。

同じPC時計でCOM6のOpen返却→読取りloop準備は1,125.6243 ms、Open返却→最初のRead開始は1,401.7539 msだった。
「COMを開いた」と「実際の読取り開始」の間には約1.40秒の準備区間がある。
この区間はloop内のservice gap 79.736 msとは測定境界が異なり、後者のPASSで起動時の待ちまで合格とはしない。
MCU側の106 ms失敗とこの区間の前後関係は、別時計のため同期なしでは確定できない。

両roleから68／112／128／128／384-byteを各2回、合計20 raw・3,280 byte取得した。
reader及びouterの独立解析は記録取得をPASSとした。
新384-byte記録のGround初回失敗は固定され、後続の診断送信で上書きされていなかった。
Vehicleの新記録は未ラッチだが、このラッチはGroundの製品Heartbeatを対象とするためVehicle正常の証明ではない。
旧68-byte記録にはVehicle `FlushFailed`、Ground `GroundBoundaryFlushFailed`も残っている。

#### Groundの最初の失敗で確定した値

| 初回の固定記録 | 実測値 |
|---|---:|
| 対象 | 製品Heartbeat、token 1、attempt 1、source line 3377 |
| USB APIへの受理 | 21 / 21 byte |
| SDK終了理由 | `LoopTimeout`、raw return false |
| 呼出し予算／SDK経過 | 106 ms / 106 ms |
| wrapperのµs実測経過 | 106,168 µs |
| lock取得待ち | 0 ms |
| ring／stash待ち量 | 0 / 0 byte |
| 期待epoch／観測epoch | 1 / 1 |
| publish／pickup generation | 3 / 2 |
| blocker mask | `0x18`、FIFO書込み不可＋payload pickup待ち |
| SDK snapshotの所要 | 8 µs |

これにより、最初の失敗はlock取得待ちやsoftware queue滞留ではなく、
**ソフトウェアがUSB payloadの完了を確認できず、106 msで待機を打ち切った境界**と分離できた。
21 byteの受理やソフトウェア待ち0は、Windows側の受信完了と同義ではない。
8 µsはこのterminal snapshot 1回の測定であり、診断全体の負荷や全実機条件の上限ではない。

wrapper flagsは`0x0D`で、API呼出し済み・endpoint ready・既存ms期限内は真、SDK raw returnだけが偽だった。
µs時刻では終了5,302,881に対し保存deadlineは5,302,000で881 µs後だが、
従来契約の比較は整数msの5,302以下5,302で真となる。この量子化差を新たな独立deadline障害とは扱わず、
失敗条件や期限を緩和していない。

PCとのnonce付き時計同期は今回も送信しておらず、両機のclock sync記録は未観測である。
従って「PC受信準備前に起きた」か「受信開始後もUSBで進まなかった」かは引き続き`UNKNOWN`。
このsnapshotだけでは、割込み処理の取りこぼしとhost側backpressureのどちらが始点かを確定しない。
raw interrupt `0x100`はstickyな`IN_TOKEN_REC_IN_EP1`であり、payload送出完了やPCアプリ受信の証明ではない。
ESP32-S3の`SERIAL_IN_EMPTY=0x8`はenable mask `0x20C`に含まれ、raw `0x100`には含まれない。
従ってこの標本は「IN_EMPTYは有効・raw pendingではない」であり、割込み無効化を確定原因とは判定しない。

#### 復旧と残課題

両機とも1回目の復旧でaccepted R18のapplication digest照合とrole再列挙に合格した。
全8子処理の終了、COM cleanup 5/5、JTAG後処理を確認し、`power_off_required=false`。
復旧後のR18通信livenessを別のCOM試験で再測定したわけではない。

outerの最終判定は`FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`。
**新記録取得PASS／初回USB完了FAIL／R18復旧PASS**を区別する。
今回の一回限定許可は使用済みで、再書込み・再試験は行っていない。
次の検討対象は初回snapshotの割込みpending／enableと再開処理、及び同じbootへのPC時刻対応付けである。
全932件30秒、製品Heartbeat最大2,500 ms、全error0、上り／下りの連続通信品質及びDeploymentは未証明／NO-GOを維持する。

### 31.53 runnerの起動時先行読取りとオフライン評価（2026-10-21 JST）

前節のOpen→初回Read約1,402 msに対し、PC側runnerだけを修正した。
**SDK／ファームウェアsource、106 msのUSB完了条件、UART／E220／TDDは変更していない。**
今回の依頼範囲は修正とオフライン評価であり、実COMの列挙・接続、JTAG、書込み、実機再試験は行っていない。
既存の一回限定実機許可を再利用せず、accepted R18の保存済み復旧資材と診断候補は変更しない。

変更は`tools/run_r19_runtime_fail_diagnostic_hil.ps1`とPC専用の`tools/r19_startup_reader.cs`である。
両readerの生成・準備と既存parser等のwarm-upをCOMオープン前に行い、
各Openの返却直後にそのroleの読取りを開始する。データが0 byteでも実際にReadを呼び、
2台目Open／post-openの機器識別確認中も読取りを継続する。
通常の読取りtimeout 20 msは無受信として数え、USB送信の106 ms条件とは混同しない。

受信byteはroleごと1 MiB／4,096 positive-read blockの有界領域へ隔離する。
**両roleのpost-open識別が成功するまでは解析・成功判定へ渡さない。**
識別不一致時も読取り済みrawは保存する。上限、read例外、停止不成立は明示的にFAILとする。
通常はStop／Joinで起動時readerの所有権を終了し、既存の単一thread parser／tail処理へ引き継ぐ。
JoinのためにCloseが必要になった試行は失敗とし、再度Stopを呼んでも通常引継ぎへ昇格させない。

初期BytesToReadの一回限りのwatermark、read batch、raw順序、実ReadのQPCを保持する。
watermarkを跨ぐ一回のReadは同じbatchのままSTARTUP_DRAIN／LIVEへ分ける。
起動時の実Read記録は停止後に同じQPCのlifecycleへ時刻順に統合し、
後続の解析時刻を受信時刻へ置き換えない。統合traceのoverflowも明示する。
Open返却→初回Readと起動時service、既存pumpと引継ぎの空白は100 ms判定を維持する。

40秒測定windowは起動時受信とは別に開始し、起点・window内frame／診断件数を保存する。
全rawには追加のstartup区間を含むことを明記し、startup中だけの診断で40秒測定をPASSにしない。
`startup_bytes`はstartup区間の完全frame長合計で、全raw byte数の代用ではない。
helperはレビューしたSHAへ固定し、封印コピーから同一byte列のhashを再確認して読み込む。
summaryへhelperの出所・保存先・byte数・SHAを保存し、呼出元outerのrunner照合値も更新した。
候補ID・BIN・JTAG reader・accepted R18の照合条件や実機許可条件は変更していない。

新規の契約11項目と実関数統合10項目はWindows PowerShell 5.1／PowerShell 7で各21/21 PASS。
最終の全host回帰は337/337 PASS（320.96秒）。内部集計は275 PASS／expected XFAIL 2／unexpected FAIL 0。
通常Vehicle→GroundのArduinoコンパイル2/2もPASSし、書込みは0回。
Groundの既存未使用変数警告1件は残る。ファームウェア／core／SDKの保存source 221件、
accepted R18保存資材8件、既存候補の封印inventory 147件を照合し、不一致0だった。
Arduinoによるsketch/build内の生成export更新はsource変更やaccepted R18更新とは区別する。
途中の全体回帰では初回のPowerShell起動環境でGet-FileHashを解決できず、次はouterの旧照合値を検出した。
Windows PowerShellで再実行し、照合条件を維持してレビュー済みrunnerのSHAへ更新後、上記の最終回帰に合格した。
データなしRead、遅い2台目Open／識別確認、未識別raw保持、部分Read、上限、read例外、
未arm終了、Close／Join失敗、一次失敗とcleanup、watermark、trace統合、window判定を確認した。
失敗試験を先に保存し、失敗済みStopの再呼出しが隔離解除を許す欠陥も検出・修正した。
意図的な100 ms超の引継ぎ遅延はFAILのまま検出され、基準を緩和していない。
試験結果・失敗時ログ・差分の入口は
`runs/validation/R19-EARLY-READER-OFFLINE-001/20261020T153047353Z/summary.json`である。

これらはメモリ内模擬sourceによるPC処理の確認であり、実USBでの改善、
MCU側106 ms完了、932件30秒、Heartbeat最大2,500 ms、製品通信／Deploymentの証明ではない。
次の実機試験は別の新規許可と安全確認のもとで行い、まず読取り開始の改善と同じ初回USB失敗の再現有無を評価する。

### 31.54 先行読取りの実機確認：開始時間は改善、106 ms失敗は継続（2026-10-21 JST）

新たな実機評価依頼に基づく1回の試験を実施した。安全条件6項目、全電源5秒以上OFF、
PC側で両USB機能の消失、再接続後のCOM3／COM6とUSB位置`1-4.2`／`1-4.4`を確認した。
候補・取得ツール・helper・復旧資材の独立照合後、並列監査を停止して実行した。
candidateは前回と同じ`20261020T123447347Z-b414028b`で、ファームウェアsource・106 ms・UART／TDD／E220設定は不変。
R19 application-only書込み→40秒dual-COM→両role内部記録→accepted R18復旧の順で行った。

実機runは`runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261020T160620750Z-10d9358b/`。
事後評価は`runs/validation/R19-EARLY-READER-HIL-REVIEW-001/20261020T160620750Z-10d9358b/summary.json`。
開始／終了UTCは`16:06:21.9552292`／`16:09:07.9003040`、日本時間10月21日01時06分〜01時09分である。

| 指標 | Vehicle COM3 | Ground COM6 |
|---|---:|---:|
| 前回Open→初回Read | 1,228.9733 ms | 1,401.7539 ms |
| 今回Open→初回Read | 4.9000 ms | 0.1702 ms |
| 起動時reader最大service間隔 | 50.2120 ms | 35.2279 ms |
| 起動時reader 100 ms基準 | PASS | PASS |
| 主処理・引継ぎ込み最大service間隔 | 158.798 ms | 112.846 ms |
| 主処理100 ms基準 | FAIL | FAIL |
| 追加startup区間の診断frame | 2 | 2 |
| 40秒window内の診断frame | ALIVE 40 | R19F 40 |
| 全raw／完全frame | 2,646 byte／42 | 2,646 byte／42 |
| CRC／noise／partial | 各0 | 各0 |

**PCアプリケーションの読取り開始前倒しは実機で確認できたが、通信問題の解消には至っていない。**
全84 frameはローカル診断で、Pixhawk／RF経由の通常完全frameは0件。40秒と追加startup区間を混同しない。
traceは共有10 MHz QPCで276 event・drop 0。COM payload writeは0回、取得ツールとhelperのSHAは一致した。

主処理へ引き継ぐ際、Vehicle最後のnative Read開始→40秒window起点だけでも152.5209 msある。
最初の主処理serviceはその後なので、Vehicleの引継ぎ部分だけで100 msを超えたことは確定する。
Groundの最初の主処理serviceまでの間隔は87.814〜112.846 msの範囲で、
最大112.846 msが引継ぎか後続処理かは未確定。空の巡回service時刻を個別保存していないため、
主処理の最初のpositive Readまでを全て停止時間とは扱わない。

#### 最初のUSB失敗と初回Readの因果順

両roleの内部記録5種類を各2回、20 raw・3,280 byte取得し、10組が同一だった。
Groundの最初の製品USB失敗は前回同様、source line3377、token1／attempt1、21/21 byte受理後の
`LoopTimeout`である。SDK予算／経過106 ms、wrapper実測105,910 µs、lock待ち0、ring／stash各0、
epoch1→1、publish3／pickup2、blocker `0x18`。raw interruptは`0x102`、enableは`0x20C`だった。
µs表示と整数ms期限の量子化差を新たなdeadline障害とは判定しない。

初回Ground raw63 byteは完全なR19Fで、line3417・5223 ms・epoch1、CRCとraw先頭一致を独立検証した。
これは初期BytesToRead=63、native batch1／offset0の全63 byteで、初回Read前の受信待ち領域に存在した。
candidateコードの順序は「製品USB失敗記録3377→runtime失敗ラッチ3417→R19F生成」である。
従って**その失敗報告の元となったラッチは、runner初回アプリケーションReadより先**と分かる。
line3377と3417は別の記録位置であり、不一致による誤診断ではない。

ただし、PC Open前だったか、何ms先行したか、物理USBの準備状態、PC未準備が根本原因かは確定しない。
R19Fにはboot nonceがなく、今回もnonce同期は0回なので、数値的なPC↔MCU時刻相関は`UNKNOWN`を維持する。
Vehicleの新記録未ラッチもVehicle正常の証明ではない。

#### 復旧・証拠と次の課題

両機とも1回目でaccepted R18のapplication digest照合・再列挙が成功した。
全8子処理終了、COM後処理5/5、両roleのCPU0／CPU1 running復帰を確認し、`power_off_required=false`。
capture／install／rollbackの封印と223ファイルのSHAに不一致0。stageは独自sealではなく、
outerが固定したsummary SHAとrawのサイズ・hash・同一組で照合した。
復旧後R18の通信livenessを追加COM試験で測定したわけではない。

最終判定は`FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`。
次はオフラインで初回主処理serviceと最大間隔の前後時刻を保存し、引継ぎ時の無読取り区間を短縮する。
別許可の診断比較では、PC読取り準備完了を確認してから最初のHeartbeatを許可する条件と、
nonce往復そのものの影響を分離する。今回これらの修正・追加試験は行っていない。
106 ms延長、RF高速化、932件30秒、Heartbeat最大2,500 ms、受入／Deploymentへの昇格は行わない。
今回の1回許可は使用済みで、両機はR18へ復旧済みである。

### 31.55 連続readerと診断用HostArmのオフライン実装（2026-10-21 JST）

ユーザー提供の追加提案を受け、まず106 msを維持したままPC側の読取り所有権の切替えを除去した。
記録・差分・最終検証結果の入口は
`runs/validation/R19-CONTINUOUS-READER-AND-HOST-READINESS-OFFLINE-001/20261020T193032512Z/summary.json`。
本節はオフライン実装の記録であり、31.54以降の新たな実機試験結果ではない。

#### 今回実装した内容

- `tools/r19_continuous_reader.cs`の単一native workerが、Open直後から終了処理まで物理Readを所有する。
  identity確認はphase記録だけとし、Stop／Join／主処理へのRead移譲を行わない。
- 主処理は固定上限のbyte予算で受信済み部分を取り出す。元のnative batch・QPC・初期BytesToRead境界を保持し、
  全native rawは解析カーソルと独立して保存する。identity不一致・例外・終了失敗時にも受信済みprefixを保存する。
- native Read間隔と主処理の解析公平性を別々に100 ms基準で評価する。
  最大間隔の前後時刻と最初の解析service時刻を保存し、最後のLIVE区間も検査する。
  既存の上限500 msの同一frame末尾drainはLIVE解析公平性と区別し、後続frameを消費しない。
  未解析suffixは全rawへ保存するが、成功扱いしない。
- 診断専用`VC_LORA_R19_USB_READINESS_MODE`を追加した。既定0は従来動作。
  1はSyncOnlyで製品USB admissionを変更しない。2はGroundの初期製品USB enqueueを抑止し、
  nonce時計応答→READY受信→明示ARMで解除する。通常製品版で非ゼロを指定するとコンパイル拒否する。
- ARMはrole／boot／reader session／nonce／実USB loss epoch／返信時刻を照合する。
  READYは排他的writerで完了確認する。受理済み21 byteをRejected後に全量再送することはない。
  ARM未到着の取得期限はsetup起点120秒で、nonce到着によって延長しない。
  待機中の古いHeartbeatの期限切れとbacklog回復は維持する。
- PC側の純粋なwire codecとC++側で、同じ54-byte payload／66-byte frameの黄金ベクターを照合する。
  この予約namespaceは診断専用で、Pixhawk／RF／GCSへ転送しない。

#### 証明範囲と残作業

メモリ内の試験では、10,000 byteを37-byteのnative Readと63-byteの配信予算で欠落・重複なく扱えた。
これは実USBの速度・106 ms完了・932件30秒・Heartbeat最大2,500 msの証明ではない。
主処理に160 msの遅延を注入した試験は、native Readが継続していても解析公平性を不合格とする。

HostArmのsource／codecは診断実装済みだが、能動PC runnerとA/B別candidate manifest・flash bindingは未統合。
封印済み候補`20261020T123447347Z-b414028b`をA/B対応候補とは扱わない。
既存のpassive outerはCOM payload write 0のままとし、この制約を緩めてARMを混入させない。
CLOCK／READYの診断writer所有中は既存同様Ground loopが一時的に早期returnし得るため、
RF／TDDが常時無停止とは説明しない。

「ARM後に成功した」は起動順序／preconditioning仮説の支持にはなるが、原因確定ではない。
PCが返信を読んだというclaimと、kernel-pending Read／物理USB host pollingも区別する。
現行TIMESYNC-shaped nonceは私的診断規約であり、標準の時刻同期を証明するものではない。
500 msで完了しないことだけから永久停止とも判定しない。

次は連続readerによる同一既存候補の再測定で、Read担当切替え由来の空白と106 ms失敗を別々に確認する。
それでも失敗する場合にA/B能動workflowと封印済み候補の束縛を完成させ、同じ観測条件で比較する。
SDKイベント履歴・非同期commit・106 ms延長・UART／TDD／E220の高速設定変更は今回行わない。
今回の作業ではCOMを開かず、書込み・JTAG・追加実機試験を行っていない。機器上のR18には未変更。

#### 配布構成・実コンパイラで検出した問題の処置

readinessヘッダーは`firmware/diagnostics/`へ隔離した。既存候補の15ヘッダーallowlistと
common／verifier／flash toolの固定SHAは維持する。手動の診断ビルドに限り同期時に
`-IncludeR19HighSpeedCandidate -IncludeR19UsbReadinessDiagnostics`を明示する。
同一の封印済み候補は、既存verifierで再照合できた。A/B候補としての昇格ではない。

実Arduino診断コンパイルでは、Windowsのパス表現差によりclockヘッダーの`pragma once`だけでは
二重定義を防げないことを検出した。失敗ログと先行する失敗試験を保存し、mode 0では従来clock、
非ゼロmodeではreadiness経由のclockと、include経路を排他的にした。正常通信の再送処理変更ではない。
Hostのfake-Arduino環境で、修正前後の通常Vehicle／Groundの前処理結果SHAが各々一致した。
これはXtensa実バイナリの同一性証明とは区別する。

全体回帰343/343 PASSの後、このinclude限定修正について関連49/49 PASSを追加確認した。
最終コンパイル結果・各ソース版・RED履歴・通常版との対応は上記`summary.json`を正とする。
実機での106 ms停止解消、932件30秒、Heartbeat 2,500 msは引き続き未確認である。

### 31.56 同一候補・連続Readの一回限定実機評価（2026-10-21 JST）

利用者の「同じ診断候補の書込み→40秒測定→内部記録取得→R18復旧」の一回限定許可と
安全条件6項目確認に基づく。全電源OFF後、PC側でもCOM3／COM6と両USB複合機能の消失を確認し、
再接続後にVehicle `COM3 / 1-4.2`、Ground `COM6 / 1-4.4`を各serial／parentに結合した。
並列監査は実機outer開始前に終了した。candidateは`20261020T123447347Z-b414028b`のままで、
HostArm、106 ms延長、UART／TDD／E220設定変更は行っていない。COM payload writeは0。

正本:

- 実機: `runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261020T223348550Z-ccb3f550/summary.json`
- 評価: `runs/validation/R19-CONTINUOUS-READER-HIL-REVIEW-001/20261020T223348550Z-ccb3f550/summary.json`
- 準備: `runs/validation/R19-CONTINUOUS-READER-HIL-PREPARATION-001/20261020T223321Z/operator_preparation.json`

outer実行区間はUTC `2026-10-20T22:33:48.4797649Z`～`22:36:30.2010519Z`、
JSTでは2026-10-21 07:33～07:36である。実行結果は
`FAIL_USB_TX_BOUNDARY_CAUSE_EVIDENCE_CAPTURED_R18_RESTORED`。
これは内部証拠取得と復旧の成功を含むが、通信PASSではない。

| 項目 | Vehicle | Ground |
|---|---:|---:|
| Open return→最初のnative Read | 5.2776 ms | 0.0648 ms |
| Open～cleanupのnative最大service間隔 | 57.4314 ms | 57.4311 ms |
| native 100 ms基準 | PASS | PASS |
| LIVE parser最大service間隔 | 303.612 ms | 268.557 ms |
| parser 100 ms基準 | FAIL | FAIL |
| raw／完全診断frame（startup含む） | 2,646 byte／42 | 2,646 byte／42 |
| 40秒測定内完全診断frame | 40 ALIVE | 40 R19F |
| CRC／noise／partial／他parser異常 | 全0 | 全0 |
| native取得後の未解析byte | 0 | 0 |

両readerはidentity確認時とLIVE marker時にも同じReadをpendingに保持した。
物理Read担当の停止・切替えはなく、native serviceは全区間100 ms以内だった。
一方、parserの最大空白はLIVE初期に残った。Vehicleの区間はPC elapsed
`1,425,706→1,729,318 us`、Groundは`1,383,675→1,652,232 us`。
個別関数・初回JIT・GC等の寄与は計測しておらず、特定原因と断定しない。
`FRAME_COMPLETE`のlifecycle tickは現行コードではparser呼出前の観測値で、
CRC／診断変換等の実処理完了時刻や費用分解に使わない。
旧main-thread／handover指標と新native／parserの指標を同一の速度改善率として比較しない。

#### 初回製品Heartbeatの失敗は継続

Groundの固定384-byte first-failure記録は、token 1／attempt 1、source line 3377、
21/21 byteのローカルUSB受理後、SDK `LoopTimeout`を示す。SDKは106 ms、wrapperは
`5,559,642→5,665,880 us`（106.238 ms）。lock待ち0、epoch 1→1、ring／stash 0、
publish 3／pickup 2、blocker `0x18`（FIFO書込み不可＋payload pickup待ち）。
整数msのcommit述語はendpoint ready=true、deadline内=true、transport published=falseである。
小さいus差だけを新しいdeadline計算bugとは扱わない。

Ground最初のnative Readは、初期`BytesToRead=63`の全63 byteをblock 0／batch 1で取得した。
それはCRC正常でsource結合済みのR19F sequence 1（runtime latch line 3417、5,665 ms）と完全一致する。
SHAは`C3F54CD7F9E9951CCEB7EE45691F4DC367441BBAEE56FFF97D34C3325C18B269`。
sealed source上、製品失敗の記録→runtime latch→R19F生成／送信の順なので、
この初回失敗は最初のPCアプリReadより先行した。後続のLIVE解析遅延だけでは初回失敗を説明できない。
ただし、PC Openより前か、先行時間が何msか、hostの物理polling状態、PC準備不足が原因かは未証明。
same-boot nonce同期0のため、MCU対PCの数値時刻関係はUNKNOWNを維持する。

40秒内の旧「32/63で末尾31 byteが止まる」診断停止は今回も未再現。
後続JTAG時のEndpoint FIFO記録はring 31、publish 98／pickup 97等を示すが、
これはcapture終了後に逐次取得した別時点の記録であり、初回製品失敗のring 0／publish 3／pickup 2と混同しない。
Vehicleのfirst-product-failure未latchも製品通信健全性の証明ではない。

#### 復旧・証明範囲・次工程

両roleの5種類×2回のraw（20サンプル）を取得した。JTAG cleanupでは各CPU0／CPU1の
`running`とshutdownを証明した。COM cleanup 5/5、8子process treeの終了も確認し、
両機をaccepted R18へ各初回でdigest照合・再列挙付き復旧した。`power_off_required=false`。
復旧後にCOMを再度開く追加liveness試験は行っていない。
独立読取り専用監査でcapture 102＋install 66＋rollback 58＝226ファイルのSHAと
各manifest／seal結合、内部20 raw（3,280 byte）のサイズ・SHAを照合し、不一致0だった。

今回で連続native Readの100 ms条件は満たせたが、parser公平性と初回製品USB完了は未合格。
932件取得、30秒、Heartbeat最大2,500 ms及び全通信error 0の同時受入は未評価である。
次のoffline対象は初期parser処理の時間上限・実測と、same-boot/session/nonceを結合した
HostArmの能動PC workflow及びA/B別sealed candidate／flash bindingの完成である。
今回の一回限定許可は消費済みで、自動再試験や新候補の書込みは行っていない。

### 31.57 ②を将来仕様へ分離、①受信準備・③完了境界のオフライン切分け（2026-10-21 JST）

利用者の依頼は、②混雑・流量制御を今回のUSB原因調査から分離して将来仕様に記載し、
①接続準備と運転の分離、③USB／RF／取得完了の独立判定で原因を切り分けることである。
今回は機器操作のないoffline診断処理・仕様追記で、実機再試験や製品機能の修復完了ではない。

記録: `runs/validation/R19-STARTUP-LAYER-CUT-OFFLINE-001/20261021T001127260Z/summary.json`。

#### ②の将来仕様と今回の非対象範囲

`SPEC.md`の`FUTURE-FLOW-001`に固定容量と滞留時間の監視、高低水位の送出抑制／再開、
Heartbeat／コマンド応答の優先枠、パラメータ欠落回復、完全frame・partial suffixの保持を記載した。
既存16 KiB上り／4 KiB下り等のbufferや、AUXによる400-byte局所creditを未実装とは扱わない。
今回の固定初回USB失敗ではring／stashが0で、buffer増量が直接原因を解消する根拠はない。
有限bufferだけで持続的な入力超過は吸収できないため、将来は送信元の流量抑制と一体評価する。
今回は容量・流量・UART・TDD・E220設定を変更しない。

#### ①のPC側手順をオフライン状態機械にした

`tools/r19_host_readiness_workflow.ps1`は、既存wire／clock codecを明示的に利用する純粋な状態機械である。
COMを開かず、書込み・実時計採取・process・networkアクセスをしない。

- 同じreader identityを維持したclock要求生成→実OUT受理記録→CRC正常な返信の実バイト確認の順を要求する。
  ExplicitHostArmでは続いてnonce／role／device boot／device session／epoch／返信時刻に合うREADYを確認する。
- SyncOnly（mode 1）はclock返信検証で完了し、実ファームが生成しないREADYを待たない。
  READY／ARMを要求せず、SyncOnlyへREADYが届いた場合はmode不一致として拒否する。
  ExplicitHostArm（mode 2）だけがREADY検証後に一度のARMを生成する。
- partial frame、partial OUT受理、古いnonce／epoch／session、順序違反、reader停止・差替え、
  PC clock domainの変更・逆行・期限超過を拒否する。初回製品Heartbeatの受理済み21 byteを全量再送しない。
- OUT受理後も`ArmWriteAcceptedAwaitingDeviceEvidence`であり、機器のARM受理やkernel-pending Readを証明しない。
- PC側取得期限はMCU setup起点120秒期限の代用ではなく、更新しない。
  mode 2は初回HeartbeatだけでなくGround製品USB出力のadmission全体を待機させるため、
  無線受信の滞留や古いHeartbeatの期限切れも別途測定する。

この追加は能動live runnerの完成ではない。既存passive runnerのpayload write 0を維持し、
現sealed候補をHostArm対応と偽らない。診断用ARMをMission Planner製品手順や飛行ARMと混同しない。

#### ③の判定器と既存実機データの再評価

`tools/r19_startup_boundary_evaluation.ps1`を追加した。ImportOnlyは純粋関数定義、
CLIは既存JSONのoffline入出力だけで、取得操作を含まない。新しい原因分類は次を分離する。

- 固定384-byte初回失敗と、後刻JTAGで読んだEndpoint FIFO状態。
- 初期受信領域の完全R19Fと、COM Open前の欠落・MCU対PCの数値時刻に関する推測。
- PC側のARM生成／OUT受理と、モード・機器boot・USB epochに結合した機器側ARM受理証拠。
- setup取得期限切れと、製品USB完了106 ms期限切れ。
- USB、RF、全パラメータの各層。未測定の下流をUSB失敗から自動的にFAIL又はPASSにしない。
- 同boot／modeの機器ARMを証明済みなのに製品失敗がARM前なら、準備不足の証明とはせず、
  gate迂回又は記録の誤結合を要確認とする。

31.56の既存raw 2回を元decoderで再検証し、outer参照のstage／capture summary、native raw、
sealed sourceのSHAを再照合して`latest_saved_run_input.json`を生成した。
再評価結果`latest_saved_run_evaluation.json`は次のとおり。

| 境界 | 再評価 |
|---|---|
| USB初回失敗 | IMMUTABLE_USB_COMPLETION_TIMEOUT、21/21 byte、106.238 ms |
| 初回失敗時software待ち／世代 | ring 0／stash 0、publish 3／pickup 2 |
| 最初のPC Read前の失敗通知 | CRC正常な全63 byteが存在 |
| 受信準備との原因分類 | UNKNOWN、機器ARM証拠なし |
| 同通知と内部記録の厳密なboot結合 | 通知にはboot nonceがなく単独では未証明 |
| 無線到達／全932件取得 | NOT_EVALUATED／NOT_EVALUATED |

R19Fを生成した停止がReadに先行するというsource上の順序は維持する。
ただし、その通知だけで固定初回記録とのboot結合やPC Open前の時刻まで昇格させない。
今回追加したoffline判定器自体も、入力の外部provenanceを認証したり原因を確定したりするものではない。

#### 実機で必要な比較条件（未統合・未実施）

| mode | USB準備交換 | 製品USB出力開始 |
|---|---|---|
| A Passive | なし | 現行どおり |
| B SyncOnly | clock／返信のみ | 現行どおり、ARM待ちなし |
| C ExplicitHostArm | clock／返信／READY／ARM | 同bootの機器ARM受理後 |

単にCだけ成功しても、起動順序と診断交換による予備作動を分離できないため原因確定としない。
現sourceではREADYもmode 2限定で、BとCは同一トラフィックではない。
ARM待機単独の因果まで主張する場合は、READYの追加送信による予備作動を揃える対照条件か、
その影響を分けられる機器内時系列の証拠が必要である。
機器ARM後も初回製品USB失敗があれば「準備往復確認後にもUSB境界で発生」と分類するが、
USB物理故障やPC host pollingの原因を自動確定しない。

実機前には、同一source基準のmode別新規candidateのseal／manifest／flash bindingと、
機器ARM受理・最初の製品enqueueを読める版番号付き固定記録及びdecoderの統合が必要である。
機器setup起点120秒の残時間も確認し、取得期限切れはUSB障害とは別の試験準備失敗にする。
既存候補・passive outerの固定pinを緩和して代用しない。新たな範囲明確な許可と安全確認後に限り実機へ進む。

#### オフライン検証と独立確認

追加した受信準備workflowはWindows PowerShell 5.1／PowerShell 7の各272項目、
境界判定器は各54項目でPASS。いずれも失敗を先に再現してから修正した。
最終sourceで`tools/run_host_tests.ps1`を実行し、全host 345/345 PASS（517.47秒）を確認した。
独立レビューで見つかったSyncOnlyの存在しないREADY待ちと、ARM前失敗を準備不足と読める判定名を訂正し、
同レビューで両指摘の解消を確認した。改訂前の264／52項目の記録は最終結果ではない。

通常版のVehicle→Ground Arduino compileも2/2 PASS。Groundには既存sourceの未使用変数warningが1件あり、
warning-freeとはしない。これらの新しいbuild出力はaccepted R18保存物やsealed R19候補へ置き換えていない。
既存sealed R19候補の読取り専用verifierはPASS、canonical bridge／HWCDC／passive runnerのSHAは未変更。

### 31.58 接続状態の無送信・受信専用確認（2026-10-21 JST）

利用者は外出中で現地操作ができないが、機器を接続済みとして検証を依頼した。
今回は新しい安全条件の現物確認を済ませたとは扱わず、既存の受信専用手順だけを1回実施した。
前節の新しいR19 mode比較手順・機器記録が未統合であることは変わらない。

記録: `runs/hil/E2E-MAV-CONNECTED-PASSIVE-RX-001/20261021T004656Z/summary.json`。

- 実行前後でCOM3 Vehicle／COM6 Groundの既知PNP IDを確認した。
  両機のUSB CDC、USB-JTAG、USB compositeの計6機能はOS上Status OK／ConfigManagerErrorCode 0。
  これは機器applicationの実行やPixhawk・RF・実JTAG接続の健全性を証明しない。
- `tools/hil_capture_serial.ps1`をCOM6、57600 bps、8N1、DTR/RTS falseで実行。
  `TransmitFile`なし、COM3は開かず、payload送信・buffer破棄・reset要求・書込み・JTAG操作は行っていない。
- 2026-10-21 09:46:58～09:47:58 JST、計60.011493秒の受信0 byte／送信0 byte。
  完全MAVLink／Heartbeatも0件。終了処理のClose／Disposeを経てprocessはexit 0。
- 元analyzerのself-testはPASS。rawとcapture footer／metadataのbyte数を照合した。
  0 frameでCRC/noise 0やHeartbeat最大間隔0と表示されても、通信品質PASSとはしない。
  Heartbeat SLA／CRC品質／上り／RF到達／932件取得は今回未評価である。

判定は`NO_DOWNLINK_OBSERVED_IN_CURRENT_CONNECTED_STATE`。
COM6を開いて受信処理が完了したことまでは確認できたが、現在の下り通信の成立は確認できない。
実機firmwareのhash読取りは行っておらず、最後にaccepted R18へ復旧した履歴だけから
今回の0 byteをR19の再発又はR18の故障と断定しない。
Pixhawkの通電・送出、E220、機器applicationの初期化、USB完了のどこで停止したかも未確定である。

追加の書込み／CPU停止／電源操作は実施していない。新しいR19診断比較を行う前には、
31.57の未統合記録・candidate／実行手順の準備と、対象・安全・復旧条件を改めてそろえる必要がある。

### 31.59 外出中のオフライン再検証・0 byteの再発履歴照合（2026-10-21 JST）

利用者の「診断統合・オフライン検証」と、今回の0 byteが新しく発生したかという問いに対する検証である。
COM、JTAG、書込み、reset、電源操作は行っていない。今回は既存診断部品の再検証と統合状態の監査であり、
残る実機統合の実装を完了したとは扱わない。106 ms、UART／TDD／E220設定は維持した。

記録: `runs/validation/R19-OFFLINE-READINESS-AND-RECURRENCE-REVIEW-001/20261021T012327Z/summary.json`。

#### 今回のオフライン検証

- 受信準備workflow 272項目、境界判定54項目をWindows PowerShell 5.1／PowerShell 7でそれぞれ再PASS。
- 関連CTest 21/21 PASS、23.95秒。全345項目を今回は再実行しておらず、前回の全件PASSと区別する。
- 現在の0 byte観測には機器初回失敗記録・ARM記録がないため、その欠測条件を判定器へ与えた。
  結果は原因分類UNKNOWN、USB障害記録NOT_OBSERVED、RF／全件取得NOT_EVALUATEDで、空入力を合格や既知USB原因へ昇格させなかった。
- Vehicle→Groundの通常版compile 2/2 PASS。BIN SHAは前回と同一だが、これらは通常版のbuild確認であり、
  新しいR19 mode 1／2の候補生成・受入又は機器書込みではない。

#### 過去の受信0 byteとの比較

| 日時（JST） | 保存済みの観測 | 判定範囲 |
|---|---|---|
| 2026-09-25 | R18の40秒受信で1,244 byte・正常42 frame。その後の別read-only preflightは0 byte | 同bootのCOM切替え・session状態をそろえない比較への注意が既に§19／20にある |
| 2026-10-10 | R19診断版の40秒dual-COMが両方0 byte | 当該runでは内部記録にWriteAccepted→FlushFailedがある |
| 2026-10-19 00:29頃 | accepted R18証明済みで90秒raw 0 byte、要求送信0、pump最大61.341 ms | R18でも同じ外見の症状があった証拠 |
| 同日01:00頃 | 両XIAO＋Pixhawk cold boot及びrunner修正後、676 byte・正常18 frame・Heartbeat16件・単一PARAM応答1件 | 往復は成立。ただし複数条件が変わっており、直前の0 byteの根因証明ではない |
| 2026-10-21 07:33頃 | R19は各COM診断2,646 byte／42 frame、製品frame 0、初回製品21 byteのUSB完了106.238 ms失敗 | 全受信0 byteとは別の観測。機器側USB記録により当該境界を確認 |
| 同日09:46頃 | 今回の受信専用60.011493秒はCOM6 rx 0／tx 0、機器firmware hash未確認 | 過去と症状は共通だが、同一原因・新規regressionとも未証明 |

各正本JSONのSHAを再照合して今回summaryへ保存した。結論は「症状は新しくないが、今回の原因まで既知とは言えない」。
過去にrunnerの空配列・起動表示・公平性などを修正した事実と、今回の無受信を引き起こした原因の証明は別である。

§19／20には、accepted R18でUSBのtxLossEpochが変わるとruntime_fail_closedを保持し、
同bootのCOM close／reopen後の出力が止まり得る既知の注意点がある。
今回にも関連する候補だが、今回のloss epoch／latch／RF／通電状態の証拠はなく、発生済みとは断定しない。
従って今回の無受信を、新しいfirmware修正で発生した故障、又は以前の106 ms失敗の再発と決めつけない。

#### 診断統合の監査で確認した残作業

MCUのgate・READY・ARM照合とPCのoffline workflowは存在するが、PCのARM送信受付は機器受理の証拠ではない。
機器ARM時刻・最初の製品enqueue・mode・full build／boot・USB epochを同じ版管理された固定記録で残す統合、
そのstrict decoder・ELF symbol／manifest・JTAG取得対応、mode別候補と専用live runnerが残っている。
既存sealed候補にはこのreadiness定義がなく、既存passive runnerもwrite 0なので流用しない。
これは検証で判明した実際の未完了範囲であり、オフライン試験PASSだけで実機試験可能又は通信改善済みとはしない。

