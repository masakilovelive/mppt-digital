# Phase 1～6 実装・実機検証レポート

実装・検証日: 2026-08-23  
対象仕様: VC-LORA-HTS-001 v1.8  
対象範囲: Phase 1（旧silence方式の不具合再現）、Phase 2（明示GRANT/DONE）、
Phase 3（固定リングバッファ）、Phase 4（MAVLink E2E）、
Phase 5（長時間・異常注入・Sanitizer）、Phase 6（production firmware・実機HIL）

## 2026-09-13 R17 Ground USB Heartbeat reserve追補

R16 production Mission Planner試験では`PARAM_VALUE` 0～931を欠落・重複・
順序違反なしで取得した一方、primary Vehicle Heartbeatに1回だけ
`2951.354 ms`（基準`<=2500 ms`）のUSB可視間隔があった。前後の実測と
TDD固定時間から、空上り周期の`550 + 650 + 550 + 650 + 550 = 2950 ms`が
Mission Planner境界へ露出したものと判断した。

test-first再現により、旧2枠へ古いage-paced Heartbeatが2件保持された時、
Grant直前の新しい実HeartbeatをPhase 6容量preflightが拒否し、予備が枯渇する
経路を固定した。Ground USB pacerだけをallocation-freeの固定3枠へ拡張し、
leased headを不変のまま一般化したFIFO置換を実装した。TDD時間、650 ms guard、
MAVLink wire、Heartbeatの生成規則、PARAM_VALUE順序は変更していない。

新規`IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001`は修正前相当`2951 ms`を
修正後`2401 ms`へ短縮し、全Heartbeat/#22をbyte-exact・FIFO・exact once、
hold age`<=2400 ms`、overflow/expiry/order drop/CRC/partial 0でPASSした。
全hostは179/179、Arduino同期、ESP32 core 3.3.11のVehicle→Ground clean compileも
PASSした。R17 firmwareの書込みとMission Planner実機再試験は未実施のため、
DeploymentはNO-GOを維持する。

## 2026-08-25 Vehicle target response priority追補

連続診断HILでは、Vehicle D6へ`PARAM_REQUEST_READ(SERIAL1_BAUD)`がexactに
1回commitされ、Pixhawk D7では一致する`PARAM_VALUE`が約193 ms後に観測された。
一方、Groundで受けたrequest後のmsg22は旧parameter listのseq 8/9/17/18/19
だけで、target seq 96は103秒待って初めて到達した。したがってtargetを
1024-frame generic `PARAM_VALUE` FIFO末尾へ置く現行schedulerが実測遅延原因である。

canonical coreへ固定8-slot request trackerと同容量target priority laneを追加した。
matching identityはindexまたはIDとtarget system/componentであり、generic FIFOを
drop・並べ替えしない。active partially-sent frameはpreemptせず、target前に許す
pending heartbeatは最大1件とする。reject時は同じprefixを再提示し、original target
完了まではmatching duplicateを抑止する。Phase 6はvalidated uplink transactionを
D6 egressへadmitした後にだけrequest identityをschedulerへ渡す。

独立監査High 3件をtests-firstで再修正した。index-addressed requestは未使用`param_id`を
duplicate判定から除外する。mixed ID/index overlapではPending ownershipをqueued duplicate
判定より先に行い、2応答を2 slotへexact onceで割り当てた後の3件目だけをfilterする。
target system/component 0はMAVLink broadcast wildcard、nonzero mismatchはgeneric FIFOである。
Phase 6 Vehicle loopは`deliver_radio_bytes` / `collect_local_ingress`の後、D6 pump前に
`!bridge_ready || runtime_fail_closed`を再検査するため、tracker Full/Invalid後のphysical
D6 write/commitは0となる。

TDD/550-msモデルでは旧msg22 18件の後に来たtargetが2300 msで完了し、heartbeat
gapは1650 msだった。追加5 testと既存host suiteはPASSである。本追補工程では
Arduino sketch同期・compile・upload・COM操作を意図的に実施していないため、
実機deployment判定は引き続きNO-GOである。

さらに`IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001`を追加した。actual Vehicle/Ground
TDD controller、`RfMediumSim`、production相当`E220WriteContract` 550-ms gateを通し、
RF #20をD6へadmitしてからrememberした。exact SERIAL1_BAUD tuple(count 932/index -1/type 6)は
request originから7614 ms、D6/target enqueueから2304 msでGroundへexact once到達した。
旧18件もschedulerから直接drainせず、39 cycleを通してGround parserへ全件byte-exact FIFOで到達した。
buffer high-waterは両role 64 B以下、same-direction remote completionは550 ms以上、
direction reverse quietは647 ms以上、wireは32 B以下である。expired/insufficient window、retry、
abandoned transactionを含むdrop/gate/collision/timeout/control CRC/parser/control leakageはすべて0である。
target周辺RF heartbeat gapは1650 ms、旧18件drainを含むfull-run RF最大gapは2959 msだった。
一意なactual RF heartbeatはwarm-up後の全区間で3件/trailing 6200 msを満たし、4到着span最大は
5159 msだった。full-run RF最大gap自体はUSB SLAではなく、Ground USB 2500-ms契約はこの供給条件と
既存heartbeat pacer/ordered-commit testsの合成とする。
監査修正後のhost runnerは167/167（165 normal＋2 expected negative）PASSである。

## 結論

- 現行制御プロトコルはversion 2、exact 32 byteである。offset 20～29を予約ゼロ、
  offset 30～31をCRC-16/CCITT-FALSEとし、旧形式との混在streamもfail-closedで再同期する。
- Vehicleの650 ms uplink guardは、`UL_GRANT`のUART受付時刻Gではなく、
  E220への物理送信完了時刻Qから開始する。したがってQ以後に650 msを全量確保する。
- 上りは1 GRANTにつき1 complete MAVLink frameをtransaction単位で隔離し、CRC-validな
  frameとmatching `UL_DONE`が揃った場合のみD6へatomic commitする。空cycleのみ`UL_IDLE`を使う。
  300 msはwhole-frameの承認／開始期限であり、開始済みdescriptorは550 ms service-floor
  pacingで有界完遂する。
  timeout起点の`late_terminal_wait_ms=1300`は絶対floorであり、raw受信活動時は
  deadlineを`max(existing, raw_now + 650 ms)`へ延長する。
- MAVLink `PARAM_ERROR`（msgid 345、CRC extra 209、payload 21/21）を実Pixhawk frameから
  定義し、urgent schedulerとGround egressで33 wire byteをbyte-exactに転送する。
- R17通常CTestは179/179成功し、論理結果は177 normal PASS＋2 expected negative＋0 unexpected FAILである。
- R17 canonicalは4 Arduino sketchへ同期し、production Vehicle/Groundをclean compile済みだが、
  R17 binaryは未書込みである。
- 診断firmwareの実機測定では、18周期すべてterminalを回収し、timeoutと半二重dropは0、
  `PARAM_REQUEST_READ` 32 byteをD6 driver境界へ正確に1回commitできた。TDD修正はPASSである。
- 変更前phase sweepは1000位相・6000周期でHeartbeat最大間隔1720 msを示したが、
  現行buffered RF scheduleの2500 ms契約は別のexpected XFAILとして保持する。transport GREENと
  Heartbeat SLAを混同せず、R17実機再測定までdeployment判定は**NO-GO**である。

## 明示TDDと制御wire形式

Vehicle/Groundは`UL_GRANT`、`UL_DONE`、`UL_IDLE`で上り送信権を明示的に管理する。
Vehicleは`UPLINK_GUARD`/`UPLINK_RECEIVE`中に送信せず、Groundは有効なGRANT lease内だけ
payloadまたはterminalを送信できる。固定timingは次のとおりである。

| 項目 | 値 |
|---|---:|
| Downlink | 3000 ms |
| Uplink guard | 650 ms |
| Uplink admission window | 300 ms |
| Vehicle receive timeout | 2000 ms |
| Return guard | 650 ms |
| Late terminal wait floor | 1300 ms |
| 物理write上限 | 32 byte |
| 同一nodeのminimum lower bound | 180 ms（production service floor 550 ms） |

制御フレームは全種類でprotocol version 2、little-endian、exact 32 byteである。

| Offset | 長さ | 内容 |
|---:|---:|---|
| 0 | 4 | magic ASCII `VCTD` |
| 4 | 1 | version=`2` |
| 5 | 1 | type: `1=UL_GRANT`, `2=UL_DONE`, `3=UL_IDLE`, `4=LINK_STATUS` |
| 6 | 1 | payload length=`12` |
| 7 | 1 | reserved=`0` |
| 8 | 2 | session_id |
| 10 | 2 | cycle_id |
| 12 | 2 | guard_ms |
| 14 | 2 | window_ms |
| 16 | 2 | max_bytes |
| 18 | 2 | actual_bytes |
| 20 | 10 | reserved zero padding |
| 30 | 2 | CRC16 |

CRCはoffset 0～29に対するCRC-16/CCITT-FALSE（poly `0x1021`、init `0xFFFF`、
xorout `0x0000`）である。decoderは固定長、magic、payload length、予約領域、CRC、
version/typeを検査し、異常候補をMAVLink endpointへ流さない。wire上の制御候補は
固定32 byte単位で隔離し、分割・連結・破損・異なるversionが混在しても次のvalid v2へ再同期する。

application dataの`0x56`と`0x7D`はlink層でescapeし、制御frameだけをrawで送る。
encoderはescape pairをwrite境界で分割せず、各wire writeを32 byte以下に保つ。
`UL_GRANT.max_bytes`と`UL_DONE.actual_bytes`はwire byteではなくapplication byteで数える。

## Guard epochと遅延上りのatomic recovery

従来の実機失敗は、VehicleがGRANTのUART受付Gからguardを数え始めたため、E220の
HIGH-only completion dwellが650 msを消費し、Groundからのdata/terminalがVehicleの
受信状態とずれたことが原因だった。現行実装ではVehicleを`GRANT_DRAIN`に保持し、
accepted GRANTの物理送信完了Qで`UPLINK_GUARD`へ遷移する。Qから650 ms未満のdataと
同一session/cycleのDONE/IDLEを受理し、Q以前の`GRANT_DRAIN`では受理しない。

通常受信timeout後は、同一cycleの遅延transactionだけを`RETURN_GUARD`で回収する。

- timeout時のdeadlineは`timeout_now + max(1300, return_guard_ms)`で開始する。
- raw活動はdeadlineを短縮せず、`max(existing, raw_now + 650 ms)`へ延長する。
- 有効DONE/IDLEまたはtransaction破棄後は、受理時刻から通常の650 ms quietへ移る。
- raw活動が連続する限りquiet deadlineは延長され得る。半二重安全を優先した契約であり、
  持続noiseによるliveness低下は残存リスクとして扱う。

Vehicle adapterはGuard、Receive、timeout起点ReturnGuardをまたいで最大64 application byteを
隔離する。完全MAVLink frameのCRC、session/cycle、protocol version、terminal type、
`actual_bytes`一致を検査し、有効DONE時だけcomplete frameをD6 queueへ一括commitする。
CRC不正、identity不一致、長さ不一致、overflow、terminal欠落ではtransaction全体を破棄する。
demux/parser residueもcycle境界でresetし、次周期へ部分frameを持ち越さない。

この動作は`UT-UPLINK-GUARD-*`、`UT-UPLINK-LATE-*`、
`IT-UPLINK-GUARD-001`、`IT-UPLINK-LATE-ESCAPE-001`、
`IT-UPLINK-LATE-HIL-001`で境界値を含めて固定した。

## Ground buffer、MAVLink parser、scheduler

Ground USB ingressは動的確保を使わない固定16 KiB complete-frame atomic ringである。
WAIT_GRANT中も入力を受理し、E220 writeが全量Acceptedになったapplication byteだけを
FIFO先頭から消費する。容量不足時は既存FIFOを保持し、新しいcomplete frameを
drop-newestとして計上する。

RF→Ground USBは固定4 KiB local egressを使う。GroundだけはUSB切断中のoverflowを
nonfatal complete-frame drop-newestとして継続し、再接続時に保持FIFOをdrainする。
Vehicle→Pixhawkのlocal egress overflowはstrict fail-closeを維持する。

`MavlinkStreamParser`は固定280 byteでMAVLink 1/2、signed MAVLink 2、CRC extraを検証し、
CRC合格済みcomplete frameだけをschedulerへ渡す。現行allow-listは80 msgidで、
ローカルMission Planner DLL照合分に実Pixhawk `PARAM_ERROR`を追加した。
固定8-slot schedulerはHeartbeat、urgent PARAM/COMMAND response、通常telemetryを優先し、
active frameを途中でプリエンプトしない。`PID_TUNING`（194）は明示filterする。

主要定義は次のとおりである。

| msgid | message | CRC extra | payload min/max |
|---:|---|---:|---:|
| 0 | HEARTBEAT | 50 | 9/9 |
| 20 | PARAM_REQUEST_READ | 214 | 20/20 |
| 22 | PARAM_VALUE | 220 | 25/25 |
| 23 | PARAM_SET | 168 | 23/23 |
| 76 | COMMAND_LONG | 152 | 33/33 |
| 77 | COMMAND_ACK | 143 | 3/10 |
| 194 | PID_TUNING | 98 | 25/33 |
| 345 | PARAM_ERROR | 209 | 21/21 |

`PARAM_ERROR` fixtureは実Pixhawkから取得したMAVLink 2 frameで、sequence 10、source 1/1、
payload 21 byte、wire 33 byteである。`UT-MAV-011`はdefinition/CRC、urgent scheduling、
Ground egressまでのbyte-exact保持を検証する。

## ホスト試験結果

固定seedは`20260817`である。正本`runs/validation/host-full-20260823T191634478Z/summary.json`の
通常CTest結果は次のとおりである。

| 集計 | 結果 |
|---|---:|
| CTest runner | 167/167 success |
| normal PASS | 165 |
| expected negative | 2 (`PHASE1-LEGACY-INVARIANT`, `IT-E220-BUFFERED-RF-HB-RED-001`) |
| unexpected FAIL | 0 |
| 全host suite | 167/167 PASS（CTest上） |

Phase 4はcontrol v2、明示`UL_DONE`、MAVLink E2E、Guard epoch、late atomic recovery、msg345を含む。
595-byteの有効MAVLink burst、payload内`VCTD`、32-byteを超えるframe、PARAM/COMMAND、
heartbeat tailを検証し、collision、control leak、部分frame、CRC error、queue順序違反を0に保った。

Phase 5では次を実施した。

- 本番timing 10000周期でGRANT/DONE 10000/10000、上り640000 byte、下り320000 byte、
  drop/timeout/collision 0。
- 2000周期の1% RF loss 32件に対し32/32復帰、0.1% control corruption 3件に対し3/3復帰。
- Ground/Vehicle交互再起動10件、AUX Busy 400～1000 msの1000周期連続注入をdeadlockなしで完了。
- 690000-byte過負荷で17184 byteを受理・順序どおり配送し、672816 byteを
  drop-newestとして明示計上。
- `ST-MAV-001`は10000周期、heartbeat 49995、最大gap 1720 ms、
  GRANT/DONE 10000/10000、drop/CRC/partial/retry 0。
- `ST-MAV-PHASE-001`はheartbeat初期位相1000通り、計6000周期で基準超過0、
  worst gap 1720 ms。

Phase 6はruntime contract、固定buffer、USB disconnect recovery、NVS identity、64-bit time、
E220 AUX/write、same-core packaging、control wire、uplink residueを検証した。

## Sanitizer結果

以下の`runs/diagnostics/tdd_v3_full_sanitizer_20260823/ctest_full.log`はservice-floor変更前の
履歴Sanitizer証跡であり、現行sourceの証跡として流用しない。target priority版はClang 22.1.8
ASan/UBSanの専用fresh buildで全167/167 PASSし、ASan/UBSan/runtime-error markerは0だった。
normal/sanitizerのJUnit・logとfreeze manifestは
`runs/validation/VEHICLE-TARGET-PARAM-PRIORITY-AUDIT-002/20260825T121001641Z/`に固定する。

| 履歴Suite | 結果 | ASan | UBSan |
|---|---:|---:|---:|
| Phase 5 | 8/8 PASS | 0 | 0 |
| Phase 6 | 12/12 PASS | 0 | 0 |
| Uplink/control targeted | 33/33 PASS | 0 | 0 |
| Full CTest（履歴） | 134/134 PASS | 0 | 0 |

4回のCTest invocationで延べ185件を実行し、ASan/UBSan reportは合計0だった。
WindowsではLeakSanitizer非対応のため`detect_leaks=0`であり、OS level leak検査は対象外である。

## Arduino production build（target priority変更前baseline）

Vehicle/Ground sketchはcanonical core/headerと
`firmware/phase6/vc_lora_phase6_bridge.hpp`のコピーを各sketch folderへ同梱する形式である。
この節のsketch copyはservice-floor baselineと同期・hash一致済みだが、target priority版
canonicalとは未同期である。
Arduino IDEでは`.ino`単体を分離せず、`VC_LoRa_Core.h`、`vc_lora/`、`src/`を含む
folder全体を開く。外部`VC_LoRa_Core` libraryは不要である。

Arduino CLI 1.3.1、ESP32 core 3.3.6、FQBN `esp32:esp32:XIAO_ESP32S3`で
Vehicle→Groundの順にfresh compileした結果は次のとおりである。

| Sketch | Flash | Global RAM | Binary size | Binary SHA-256 |
|---|---:|---:|---:|---|
| Vehicle | 391803 byte | 97304 byte | 391952 byte | `4431DCB13DF662F91413700A8B2EFFE2F6A9E2A03473B6C3419C9C6C7CDBFC86` |
| Ground | 364003 byte | 62848 byte | 364144 byte | `095C9BE529DFA24A544CAE544801B9E5D702CB181AFB87DBBD6DC62DAE334BCB` |

- Source file count: 106
- Source tree SHA-256: `B835173B1AA3837CEBDB94F1F0AEBFBC682EA0084E6A5E7D41F0C134DD2EE2D6`
- Firmware manifest SHA-256: `BBE61DE437D8E624A8016A53AAFC72C43B5C12ED9038C54FFEE72B7393EB56E0`
- Contract check: PASS
- Ground USB debug text match: 0

不変正本は`runs/validation/final_production_compile_20260823T192757014Z/`である。

## Production flash証跡

`runs/phase6_arduino_compile/flash_evidence.json`は旧v2書込みの履歴である。

| Role | Port | Device identity | Binary | 結果 |
|---|---|---|---|---|
| Vehicle | COM3 | MAC `90:70:69:11:81:a4` | 322192 byte / `DA3BEB...E54C00` | upload exit 0、esptool hash verify PASS、再列挙一致 |
| Ground | COM6 | MAC `1c:db:d4:5a:83:80` | 350128 byte / `237BEB...30350C` | upload exit 0、esptool hash verify PASS、再列挙一致 |

target priority変更前のv2 service-floor baselineは同期・clean compile・Vehicle→Ground書込み済みである。
各roleでMAC一致、hash verify 4/4、hard reset、同一PNP再列挙を確認した。正本は
`runs/hil/PROD-V2-PACING-HB-UPLOAD-001/20260823T194053048Z/`である。

## 診断firmware HIL: TDD修正 PASS

有効なMAVLink 2 `PARAM_REQUEST_READ`（`SERIAL1_BAUD`、msg20、exact 32 byte、
SHA-256 `821F1FE12A93B30FF42EEDB0CDA9CC7DE6A8D4D4E7347BDD2CB0B3A07572E2CC`）を
COM6から1回送った。90.008秒のcaptureはRX 6039 byte、306 valid frames、TX 32 byte、
bad CRC/noise/partial/control leakはいずれも0だった。

診断counterのbefore/after差分は次のとおりである。

| 観測 | 差分・結果 |
|---|---|
| Vehicle GRANT | +18 |
| Vehicle terminal | DONE +1、IDLE +17、timeout +0 |
| Ground GRANT | +18 |
| Ground terminal TX | DONE +1、IDLE +17 |
| Ground half-duplex drop | 0 |
| Vehicle radio ingress | msg20 1 frame / 32 byte |
| Vehicle D6 driver accepted | msg20 1 frame / 32 byte、commit 1 |
| Vehicle D7 | 4876 valid frames、CRC error 0、msg22 0 |

対象transactionはGuard/Receive/late ReturnGuardを経て、同一session/cycleのDONE、
`actual_bytes=32`、terminal gap 551 msを検証し、D6 driverへ正確に1回だけcommitされた。
18周期でterminal未回収、timeout、duplicate/future/stale/expired、半二重dropは発生していない。
したがってQ起点guard、late wait、atomic recoveryを含むTDD software pathは実機でPASSした。

証跡:

- `runs/hil/E2E-MAV-LATE-TERMINAL-001/20260818T204238473Z-ground-com6/measurement.json`
- `runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204417011Z-vehicle-after/response.txt`
- `runs/hil/FW-LATE-TERMINAL-DIAG-001/20260818T204417396Z-ground-after/response.txt`

## Production HILとdeployment判定

production firmware書込み後、同じ`SERIAL1_BAUD` requestをCOM6から送信して90.013秒測定した。

| 項目 | 結果 |
|---|---:|
| TX | msg20 1 frame / 32 byte、CRC error 0 |
| RX | 271 valid MAVLink frames / 5390 byte |
| RX integrity | bad CRC 0、noise 0、partial 0、control leak 0 |
| PARAM_VALUE (msg22) after request | 0 |
| PARAM_ERROR (msg345) after request | 0 |
| Heartbeat | 115 frames |
| Heartbeat最大間隔 | 4098.309 ms |
| Heartbeat基準 | 2500 ms |

同じfixtureをPixhawk COM26へ直接送ったcontrol測定はPASSし、`SERIAL1_BAUD`を含むmsg22が
46.38 msで返った。したがってfixture、Pixhawk parameter handler、msg22解析は正常である。
診断HILはrequestをD6 driver境界まで証明したが、その後D7にmsg22は現れなかった。

現時点の未解決範囲は次のいずれかである。

- Vehicle D6（XIAO TX）からPixhawk RXまでの電気的連続性・信号品質
- D6が接続されているPixhawk TELEM connector/pinの選択
- 対象FC UARTのRX、baud、flow-controlを含む受信設定

read-only取得ではSERIAL1/2_PROTOCOL=2、BAUD=57、OPTIONS=0、MAV1/2_OPTIONS=0だが、
BRD_SER1/2_RTSCTS=2 (Auto)で要求値0と一致しない。本診断でparameter mutationは行っておらず、
この差はflow-control切り分けの次候補とする。

ソフトウェアとTDD修正はhost、Sanitizer、診断HILでPASSしている。一方、実運用の
parameter round-tripはmsg22=0で、Heartbeat gapも受入基準を超えたため、最終判定は次のとおりである。

- **Software / host preflight: GO**
- **Current target-priority source Arduino sync / build / flash: NO-GO（未実施）**
- **Current-source power-cycle / HIL: NO-GO（未実施）**
- **TDD diagnostic path through D6 driver: GO**
- **Mission Planner parameter read/write deployment: NO-GO**

次の作業は、canonicalを正式にArduino copyへ同期・clean compileし、承認binaryを
Vehicle→Ground順に書き込み、両XIAO/E220を完全電源再投入した後、
同じ32-byte msg20の反復round-tripとHeartbeat SLAを測定することである。これが全件PASSした後だけ
Ground-owned proxyの短縮試験、full parameter listへ進む。active download中のparameter writeは行わない。

正本証跡:

- `runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/judgment.json`
- `runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/measurement.json`
- `runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/pixhawk_serial_parameters_readonly.json`
- `runs/hil/E2E-MAV-PARAM-VALID-DIRECT-POSTFIX-001/20260818T205427859Z-pixhawk-com26/measurement.json`

## 維持したhardware/runtime契約

- E220: `D0=M0`, `D1=M1`, `D2=XIAO TX -> E220 RXD`,
  `D3=XIAO RX <- E220 TXD`, `D8=AUX`
- Pixhawk: `D6=XIAO TX -> Pixhawk RX`, `D7=XIAO RX <- Pixhawk TX`
- Pixhawk/GCS UART: 57600 bps、8N1
- E220 UART: 115200 bps、8N1
- E220 profile: `00 00 E5 C3 46 00 00 00`
- `partial_flush_ms=50`は互換contractで、complete-frame production pathのtimer判断には未使用
- NVS identityはread/write/readback成功後だけleaseし、失敗時はradio TXをfail-close
- 時刻は`esp_timer_get_time()`由来の64-bit monotonic ms
- E220 full writeだけをcommitし、zero writeはexact retry、partial write/AUX timeoutはfail-close
- E220 full write後はAUX連続HIGH/LOW→HIGHの両方で550 ms service floorとHIGH連続15 msを必須とする
- started Ground transactionは最初のDATA Acceptedから2000 ms内にDATA＋`UL_DONE`を完了できなければfail-closeする

## 主な実装・証跡ファイル

- Protocol/TDD: `core/include/vc_lora/tdd_types.hpp`,
  `core/include/vc_lora/tdd_control_codec.hpp`, `core/src/tdd_control_codec.cpp`,
  `core/src/tdd_vehicle.cpp`, `core/src/tdd_ground.cpp`
- Late recovery: `core/include/vc_lora/late_uplink_recovery.hpp`,
  `core/src/late_uplink_recovery.cpp`, `tests/host/unit/late_uplink_recovery_tests.cpp`
- MAVLink: `core/src/mavlink_frame.cpp`, `core/src/mavlink_scheduler.cpp`,
  `tests/host/unit/mavlink_tests.cpp`, `tests/host/fixtures/mavlink/MANIFEST.md`
- Firmware adapter: `firmware/phase6/vc_lora_phase6_bridge.hpp`
- Production sketches: `vc_lora_vehicle_xiao_esp32s3/`, `vc_lora_ground_xiao_esp32s3/`
- Current host/sanitizer source-freeze evidence:
  `runs/validation/VEHICLE-TARGET-PARAM-PRIORITY-AUDIT-002/20260825T121001641Z/`
- Historical target-priority-before Arduino compile:
  `runs/validation/final_production_compile_20260823T192757014Z/`
- Historical Arduino flash: `runs/phase6_arduino_compile/flash_evidence.json`
- Current buffered transport (exact32 and Vehicle 45-byte/64-wire atomic commit):
  `runs/e220_service_floor_vehicle_transport_green/summary.json`
- Current started-transaction watchdog: `runs/e220_started_tx_bounded_green/summary.json`
- Diagnostic HIL: `runs/hil/FW-LATE-TERMINAL-DIAG-001/`,
  `runs/hil/E2E-MAV-LATE-TERMINAL-001/`
- Production HIL: `runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/`,
  `runs/hil/E2E-MAV-PARAM-VALID-DIRECT-POSTFIX-001/`
