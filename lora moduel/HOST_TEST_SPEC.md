# VC LoRa Bridge ホスト試験仕様（実装版）

- 文書番号: VC-LORA-HTS-001
- 版: 2.2 / Phase 1～6実装＋R19 read-only CDC bootstrap物理再評価追補
- 基準日: 2026-10-03
- 固定seed: `20260817`

本書は`VC_LoRa_Host_Test_Specification_JA.md`のPhase 1～6を、この
リポジトリで再実行できる形に固定する。
R17の件数と判定は履歴baselineであり、末尾のR19追補を現行結果とする。

## R17 Ground USB Heartbeat pre-Grant reserve（2026-09-13追加）

R16のMission Planner実機試験は`PARAM_VALUE` index 0～931を欠落・重複・
順序違反なしで取得したが、primary Vehicle Heartbeatに1回だけ
`2951.354 ms`のUSB可視間隔を記録した。これは空上り周期の固定経路
`550 + 650 + 550 + 650 + 550 = 2950 ms`と一致する。

Ground USB pacerの旧2枠が古いage-paced Heartbeatで埋まると、Phase 6の
容量preflightがGrant直前の新しい実Heartbeatを`ingest()`前に拒否し、古い2件を
排出した後の空上り周期を橋渡しする予備が無くなる。R17では実Heartbeat保持を
固定3枠へ拡張する。動的確保、synthetic/re-encoded/replayed Heartbeat、TDD時間、
650 ms guard、MAVLink wire、PARAM_VALUE順序は変更しない。

`IT-GROUND-USB-HB-PHASE6-PREGRANT-RESERVE-001`は、古い2件を保持した状態で
Grant直前の3件目を供給し、修正前2枠では`2951 ms`となるREDを固定する。
3枠では全Heartbeatと対応する`PARAM_VALUE`をbyte-exact・FIFO・exact onceで保持し、
最大USB完了間隔を`2401 ms`（基準`<=2500 ms`）、最大保持ageを`<=2400 ms`とする。
overflow、expiry、order drop、CRC/partial異常は0である。

R17 canonicalのCTest runnerは179/179成功し、論理結果は177 normal PASS、
2 expected negative、unexpected FAIL 0である。4 Arduino sketchへの同期と
ESP32 core 3.3.11でのVehicle→Ground clean compileもPASSした。R17 binaryの
upload・COM接続・Mission Planner実機再試験は未実施のためDeploymentはNO-GOとする。

## Vehicle target PARAM_VALUE priority（2026-08-25追加）

103秒の実機待機で判明したVehicle側の旧`PARAM_VALUE` FIFO滞留を対象に、
次のホスト契約を追加する。D6へadmit済みの`PARAM_REQUEST_READ`の
`param_index` / `param_id` / target system/componentを固定8件で記憶し、
一致するD7 `PARAM_VALUE`だけを固定8-frame priority laneへ入れる。
既存1024-frame / 64-KiB generic FIFOのframeはdrop・並べ替えしない。
index指定ではMAVLink上未使用の`param_id`をduplicate identityから除外し、target
system/componentの0はbroadcast wildcardとする。responseがID requestとindex requestへ
同時に一致する場合、Pending ownershipを各slotへ先に割り当て、Pendingが無い場合だけ
queued duplicateをfilterする。

| Test ID | 固定する境界 |
|---|---|
| `UT-VEHICLE-PARAM-PRIORITY-BACKLOG-001` | 旧msg22 18件＋1-Hz heartbeat＋target 19番目。650-ms return guard、3000-ms downlink window、32-byte escaped write、550-ms service floorでtarget 2300 ms（30秒以下）、heartbeat gap 1650 ms（2500 ms以下） |
| `UT-VEHICLE-PARAM-PRIORITY-RETRY-001` | target初回write reject後のbyte-exact retry、accepted chunk、response duplicate抑止、completion exactly once |
| `UT-VEHICLE-PARAM-PRIORITY-MATCH-001` | index modeのunused ID無視、mixed ID/index overlapの2-slot exact completion＋3件目filter、target 0/0 wildcard、nonzero mismatch generic FIFO、8-slot上限、reset |
| `UT-VEHICLE-PARAM-PRIORITY-BOUNDARY-001` | partially-sent frame非preempt、target前heartbeat最大1件、generic FIFO維持 |
| `UT-VEHICLE-PARAM-PRIORITY-PHASE6-001` | validated uplinkをD6 egressへadmitした後だけrequestを記憶。tracker Full/Invalid後はdeliver/collectとD6 pumpの間で即停止し、physical D6 write/commitを0に固定 |
| `IT-E220-BUFFERED-VEHICLE-PARAM-PRIORITY-001` | actual Vehicle/Ground controller＋RfMedium＋production-equivalent 550-ms write gate。RF #20→D6 admit→remember、旧18＋exact SERIAL1_BAUD target(count932/index-1/type6)＋1-Hz HB。R0→Ground target 7614 ms、D6→Ground 2304 ms、target exact1、旧18全件をactual Ground parserでbyte-exact FIFO、buffer<=64 B、wire<=32 B、same-direction completion>=550 ms、direction reverse quiet>=647 ms、HB sequence/wire一意かつ各4到着span<=6200 ms（実測最大5159 ms）、全drop/gate/timeout/CRC違反0 |

REDはproduction編集前に
`runs/work/UT-VEHICLE-PARAM-PRIORITY-RED-001/20260825T111754832Z/red_build.log`
へ保存した。独立監査Highの再修正REDは
`runs/work/UT-VEHICLE-PARAM-PRIORITY-AUDIT-RED-002/20260825T115048739Z/`
に保存し、index identityとpre-D6-pump fail-stopを別々のexit 1で固定した。
canonical core/Phase 6のGREEN後もArduino sketch copyの同期、
Arduino compile、upload、COM操作はこの変更工程の対象外とする。

new ITのtarget周辺RF heartbeat gapは1650 msだった。旧18件のactual RF drainを含む
full-run RF最大gapは2959 msであり、これをGround USB SLAと混同しない。USB出力の2500-ms
契約は、new ITが示す一意なactual RF heartbeat 3件/trailing 6200 ms供給と、
`IT-GROUND-USB-HB-PACER-TIMING-001`およびPhase6 ordered-commit testsの合成を正本とする。

## 実装済み範囲

1. 旧Groundの「最後の受信から650～950 msなら送信可能」という判定を
   `LegacySilenceGroundGate`で再現する。
2. 疎な下りと旧Ground送信を重ね、未許可送信と衝突が発生することを
   `PHASE1-LEGACY-COLLISION`で特性試験する。さらに、同じ事象が明示GRANTの
   不変条件に違反することを`PHASE1-LEGACY-INVARIANT`の期待失敗で固定する。
3. Vehicle/Ground TDD状態機械、TX gate、制御codec、診断カウンタを
   Arduino非依存C++17として`core/`へ分離する。
4. `UL_GRANT`、`UL_DONE`、`UL_IDLE`、`session_id`、`cycle_id`を扱う。
5. 仮想時計、ローカル時計offset/skew、E220送受信中AUX、115200 bps UART、
   半二重RF、方向転換、衝突、loss/corruption/duplication、UARTバッファ超過を
   ホスト上で模擬する。受信側が送信中に到着したフレームは破棄して診断する。
6. 固定16 KiBのGround USBリングバッファをホストcore/simulatorへ追加し、
   GRANT待ちを含めTDD状態と独立したingressから入力を受ける。overflowは既存
   FIFOを保持するdrop-newestとし、RF書込みがAcceptedになったbyteだけを
   先頭から消費する。Phase 6では同じframe-atomic ingressをGround native USB CDCの
   常時pollへ接続し、overflow/dropをfail-closeする固定adapterを実装する。
7. 1 GRANTの最大64 application byteを1論理transactionとして維持し、E220物理writeを
   最大32 byteに分割する。300 ms窓はwhole-frame descriptorの承認／開始期限である。
   adapterは開始前に選択frame全体のapplication/wire長をpreviewする。最初のprefixがAccepted後は
   同一descriptorのみ550 ms service-floor pacingで窓外まで有界継続し、全target後に
   明示`UL_DONE`を送る。64-wire descriptorは2 DATA＋DONEを2000 ms内に完了し、96-wire/
   oversize descriptorはprefix 0の`UL_IDLE`とする。
8. 固定280 byteのMAVLink 1/2 parserで長さ、80 msgidの既知CRC extra、MAVLink 2
   signatureを検査し、CRC合格した完全frameだけをendpointへ渡す。
9. 固定8 slotのMAVLink schedulerでheartbeat、PARAM/COMMAND応答、通常trafficの
   優先度を扱う。送信中frameはプリエンプトせず、有効な`PID_TUNING`
   (msgid 194)は明示filterしてframe/byte数を診断する。
10. link dataの`0x56` (`V`)、`0x7D`、`0x7E`を`0x7D, byte^0x20`へescapeし、
    `VCTD`制御frameはrawで流す。nonempty data writeはraw `0x7E`でexact32へpaddingし、
    demuxでpaddingだけを破棄する。Acceptedのapplication byte数だけをcommitする。
11. Vehicleの3000 ms境界で通常の新規frameは開始しないが、開始済みframeは
    完了してから`DOWNLINK_DRAIN`へ移る。有効Heartbeatを一度観測した場合だけ、
    nominal境界起点の1100 ms以内に現れたCRC合格済み実Heartbeatを1 frame選択する。
    選択後はAUX/readiness/Rejectedをまたいで同一frameを保持し、通常frameをtailとして
    誤送信しない。未選択/no-HB/availability消失は有界にdrainする。
12. Phase 4はlink escape/accounting 9件、MAVLink境界8件、MAVLink core 11件、
    `E2E-MAV-001`～`010`、Uplink Guard/epoch 7件、Residual 4件、late recovery 12件、
    `IT-UPLINK-GUARD-001`、control v2/sub-packet/Heartbeat slotを実施する。`UT-LINK-ACCOUNT-003`で
    encoded prefixのapplication/wire previewに基づく窓内fit判定を固定する。
13. Phase 5は`ST-001`～`006`、本番MAVLink経路10000周期の`ST-MAV-001`、
   heartbeat初期位相0～999 msを全探索する`ST-MAV-PHASE-001`の8件を検証する。
   loss/corruption、交互再起動、AUX Busy jitter、連続過負荷、heartbeat cadenceと
   heartbeat停止2周期を対象とする。trace保持は固定2048 event、RF履歴/配送待ちは
   固定上限で運用し、実測high-waterはいずれも1 transmissionとする。
14. Clang 22.1.8のAddressSanitizer/UndefinedBehaviorSanitizerを有効にした別buildで
   Phase 5の8件を再実行する。WindowsではLeakSanitizerを利用できないため
   `detect_leaks=0`とし、この制約を結果へ明示する。
15. 各試験の`runs/<TEST-ID>/summary.json`を保存する。失敗時、明示指定時、
   Phase 1特性試験では`trace.csv`も保存する。
16. Phase 6は接続・操作・parameter・command・mission・log系46 msgidと、
   telemetry/status系34 msgidをローカルMission Planner `MAVLink.dll`へ照合する。
   `SET_MODE`、manual/RC、guided setpoint、log系を含め、未知msgidはfail-closeする。
17. `SYSTEM_TIME` (2)と`TIMESYNC` (111)を別々のrate bucketで各1 Hzに制限する。
18. Ground 16 KiB frame-atomic ingress、Vehicle/Ground local egressを固定容量adapterへ接続し、
   local UARTのshort/zero writeでは未送信suffixだけを再試行する。4 KiB local egress満杯時は
   Ground USBだけ新しいcomplete frameをdrop-newestして処理を継続し、Vehicle→Pixhawkは
   fail-closeを維持する。partial radio writeはprefix境界が不明になるためfail-closeし、
   zero radio writeは同一prefixを保持する。
19. boot/session IDはNVSへ非0・単調・wrap後1として永続化し、書込み後readbackできるまで
   leaseしない。production adapterは`esp_timer_get_time()`を64-bit単調時刻として使う。
20. E220 full write後は、AUXが連続HIGHでもLOW→HIGHでも、full受付から550 ms経過かつ
   HIGH連続15 msまでbusyとする。LOWを途中で観測してもfloor起点を変えず、LOW継続2 s、
   partial write、時刻後退でfail-closeする。180 msは従来のminimum lower boundだが、550 msが支配する。
21. 固定pin/UART/profileをcompile-time契約化し、profileの読出し・修正・再検証または
   identity永続化に失敗した場合は通常radio TXを開始しない。
22. hostと同じcanonical core source/headerとadapterのコピーを各production sketchへ同梱し、
    production化前に明示同期とhash一致を必須とする。現行550 ms/watchdog変更は同期・hash一致確認済みである。
   Arduino IDE直開きでは外部`VC_LoRa_Core` libraryを要求せず、Ground USBはMAVLink専用で、
   debug文字列・独自binary・synthetic heartbeatを禁止する。同期はcore/adapter変更時の明示
   スクリプト実行に限定し、contractでcanonical copyのファイル集合とSHA-256一致を検査する。
23. 旧binaryの実機HILでGround COMを約112秒開かなかった場合、4 KiB local egress overflowが
   永久`runtime_fail_closed`へ伝播することを検出した。`FW-USB-DISCONNECT-001`でGroundの
   nonfatal complete-frame drop-newest、100 frame drop、pending short-write、FIFO、再接続、
   容量境界を固定し、Vehicleのstrict policyが変わらないことも確認する。
24. Vehicleは現行GRANTの受信窓内に到着した上りdata、および同一session/cycleを検証した
   `UL_DONE`、`UL_IDLE`を`UplinkGuard || UplinkReceive`で受理する。data wire自体には
   session/cycle fieldがない。`GrantDrain`と`ReturnGuard`は閉じたままとし、controlの
   異なるsession/cycleは従来どおり拒否する。`UT-UPLINK-GUARD-*` 6件と
   `IT-UPLINK-GUARD-001`で早着data/control、境界、identity、GrantDrain禁止を固定する。
25. Vehicle/Groundとも受信窓が閉じている時および閉じた直後にlink demuxと部分MAVLink
   parserをresetする。ただし完成済みlocal egress queueは保持する。
   `UT-UPLINK-RESIDUAL-*` 4件で閉窓中の`0x7D`/`V` prefix、DONE/timeoutをまたぐ部分msg20を、
    `FW-UPLINK-RESIDUAL-CONTRACT-001`でproduction adapter契約を検証する。
26. TDD controlはversion 2のexact 32 byteとし、offset 20～29は0 padding、
    offset 30～31は0～29に対するCRC-16/CCITT-FALSEとする。混在する旧candidateは
    resyncのため隔離するが、現行controlとしてdecodeしない。
27. Vehicleの650 ms guard epochはGRANTの物理drain点Qに設定する。通常timeout後は
    `late_terminal_wait_ms=1300`の絶対floorを設け、raw radio活動ごとに`raw_now+650 ms`へ
    延長する。raw活動でfloorを短縮しない。
28. v2 data cycleは1 GRANTにつき1 complete MAVLink frameを隔離し、matching `UL_DONE`の
    session/cycle/actualを照合した後だけD6/local egressへatomic commitする。IDLEはpayloadなし、
    CRC/identity/overflow異常は全量破棄し、有効terminal後は固定650 ms guardとする。
29. 最初のDATA prefix Accepted時から2000 msをstarted-transactionの絶対deadlineとする。
    `radio_tx_empty`/writer capacityの永続falseやwrite=0/Rejected反復がdeadlineを超える場合は、
    partial DONEを出さず、suffixを次cycle/sessionへ流さずruntime fail-closeする。同一境界で
    観測済みのradio completionはtimeoutより先に受理し、future-write capacityはcompletion判定に使わない。

## 2026-08-25 baseline実施結果（R17集計は冒頭追補を正とする）

CTest runnerは167/167件が成功し、論理結果は165 normal PASS、2 expected negative、
unexpected FAIL 0件である。expected negativeは旧方式の不変条件違反`PHASE1-LEGACY-INVARIANT`と、
transportと分離したRF schedule単体のHeartbeat SLA `IT-E220-BUFFERED-RF-HB-RED-001`である。

`FW-USB-DISCONNECT-001`はGround USB出力queueに完全frame 3件/63 byteを保持し、先頭
32-byte writeのうち7 byteだけをacceptした状態で、続く100 frameを完全frame単位で
drop-newestした。endpointはfail-closeせず、再接続後のFIFO stream、次frameの再開、
42-byte exact-capacity受理、1 byte不足時の全frame dropがbyte-exactだった。Vehicle側の
同じoverflowはfail-closeを維持した。

`IT-TDD-001`は100周期でGRANT/DONEを各100回完了し、上り6400 byte、下り
3200 byteを配送した。衝突、TX gate違反、未許可Ground TX、Vehicle受信窓中TX、
制御byte漏れ、uplink timeout、方向転換破棄、半二重破棄、UARTバッファ破棄は
すべて0である。

Phase 3では595 byte、8 KiB、16 KiBの入力を実byte列で照合した。8 KiBは
最初のGRANT前から保持して128 GRANTで、16 KiBは有効GRANTのguard中に一括入力し
256 GRANT・512回の32-byte物理書込みで配送した。drop、overflow、順序不一致は
すべて0である。容量超過試験では16,416 byte中16,384 byteを受理し、末尾32 byte
だけを明示dropした。RF書込み拒否試験では先頭64 byteを保持したまま後続32 byteを
受理し、再試行後に96 byteのFIFO順序を維持した。

Phase 4のMAVLink E2E 10件はすべてPASSした。Pixhawk heartbeatは60/60、
最大受信間隔1507 ms、GCS heartbeatは20/20である。`PARAM_REQUEST_READ`→
`PARAM_VALUE`、`PARAM_SET`→更新→`PARAM_VALUE`、`COMMAND_LONG`→`COMMAND_ACK`は
それぞれ20/20をraw byte、順序、応答対応付けまで確認した。32 byte超frameは
両方向で完全frameだけをendpointへ渡し、物理writeは32 byte以下だった。

有効な`PARAM_SET` payload内のraw `VCTD`列はescapeにより無変更で配送し、
GRANT/DONEは正常処理、制御byte漏れは0だった。msgid 194は32 Hz×60 sの
1920/1920 frameをfilterしつつheartbeat 60/60、最大間隔1507 msを維持した。
有効なMAVLink 2 `PARAM_SET` 17 frameの595 byte burstは入力595 byte、受理/
dequeue 595 byte、drop 0、最大Ground queue 595 byteで完全一致した。MAVLink queueの
最大は17 frame/595 byte、drain後は正確に17 frame受信・Ground queue 0 byteである。
各frameの17 CRCはmanifestの独立golden値と照合した。

`E2E-MAV-010`はHeartbeatを観測後に入力を2 TDD周期停止し、各no-HB周期が
nominal+1100 msで有界GRANTへ進み、deadlock/合成Heartbeatなしで完了することを確認した。
次周期のnominal境界で再開したHeartbeatはtailとしてexact byte/hash一致で1 frameだけ届いた。

`UT-MAV-BOUNDARY-003`～`008`は、no-HB時の通常frame不送信と有界drain、1100 ms
inclusive endpointの実Heartbeat 1 frame、endpoint busy時のselected latch、availability
消失時のnormal不送信、signed MAVLink 2 Heartbeat 34 byteのescape後2 write・Rejected
同一prefix再試行、AUX High 15 ms安定待ちを固定する。各writeは32 byte以下、部分frame、
重複Heartbeat、通常frame誤送信は0である。production E220経路のAccepted writeは550 ms
service floorでgateする。

全Phase 4 E2Eでcollision、loss、TX gate違反、制御byte漏れ、部分MAVLink配送、
CRC error、parser reset、queue drop、action retryはすべて0である。さらに全物理writeが
32 byte以下であることをassertする。現行buffered production contractは、新transactionの最初のwriteが
300 ms admission window内、開始済みdescriptorのみ窓外継続、remote completion間隔>=550 ms、
64-wireの2 DATA＋DONEが2000 ms内、96-wireはprefix 0であることを
`IT-E220-BUFFERED-UPLINK-001`と`IT-PARAM-PROXY-TDD-V2-001`でgateする。

MAVLinkのローカルMission Planner fixtureは主要E2E対象をraw固定配列で持つ。
`tests/host/fixtures/mavlink/MANIFEST.md`にMission Planner 1.3.83 build 1.3.9384.38258、
MAVLink.dll 1.0.7のproduct version/SHA-256、dialect、CRCを記録した。

Phase 6の`FW-MAV-001`は接続・操作・parameter・command・mission・log系46定義、
`FW-MAV-002`はtelemetry/status系34定義、合計80 msgidのCRC extraとpayload min/maxを
同DLLへ照合した。`SET_MODE`、`MANUAL_CONTROL`、`RC_CHANNELS_OVERRIDE`、
`SET_POSITION_TARGET_LOCAL_NED` / `GLOBAL_INT`、`LOG_REQUEST_*` / `LOG_*`を含む。
下表はE2E golden fixtureで直接使用する代表messageであり、80件全体の一覧は
`core/src/mavlink_frame.cpp`を正とする。

| msgid | message | payload min/max |
|---:|---|---:|
| 0 | HEARTBEAT | 9/9 |
| 20 | PARAM_REQUEST_READ | 20/20 |
| 22 | PARAM_VALUE | 25/25 |
| 23 | PARAM_SET | 23/23 |
| 76 | COMMAND_LONG | 33/33 |
| 77 | COMMAND_ACK | 3/10 |
| 194 | PID_TUNING | 25/33 |
| 345 | PARAM_ERROR | 21/21 |

`PARAM_ERROR` (345)はCRC extra 209で、無効`ARMING_CHECK`要求に対する実Pixhawk frameと
独立fixtureを`UT-MAV-011`で検証し、urgent scheduler/egress forwardも固定した。

### Phase 5 長時間・異常注入結果

固定seed `20260817`でPhase 5は8/8 PASSした。Phase 5のhost gateと、後述する
Phase 6ファーム統合判定は分けて扱う。

| ID | 条件 | 実測結果 |
|---|---|---|
| ST-001 | 本番timing、10000周期、毎周期上り64 byte/下り32 byte | GRANT/DONE 10000/10000、上り640000 byte、下り320000 byte、drop/timeout 0 |
| ST-002 | 空上り2000周期、RF loss 1% | loss/timeout/recovery 32/32/32、最大復帰2周期、最終pending 0、未許可TX 0 |
| ST-003 | 空上り2000周期、control corruption 0.1% | CRC異常/timeout/recovery 3/3/3、誤状態遷移0、最大復帰1周期、最終pending 0 |
| ST-004 | 100周期ごとにGround/Vehicleを交互再起動 | 1100周期、再起動/復帰10/10、Vehicle session変更5、最大復帰1周期 |
| ST-005 | 1000周期、Ground AUX Busy 400～1000 ms | 1000/1000復帰、32000 byte全配送、drop/timeout 0、drain完了 |
| ST-006 | 115 byte/10 msを60 s連続入力 | 690000 byte中17184 byte受理・全配送、672816 byteを定義どおりdrop-newest、最大queue 16384 byte |
| ST-MAV-001 | parser/scheduler/frame-aware ring/escapeを通す本番MAVLink経路10000周期 | **PASS**: heartbeat 49995、最大gap 1720 ms、GRANT/DONE 10000/10000、drop/partial/retry 0 |
| ST-MAV-PHASE-001 | heartbeat初期位相0～999 ms、各6周期（末尾no-HB 2周期） | **PASS**: 6000周期、基準超過0/1000、worst 1720 ms、deadlock/timeout 0 |

`ST-MAV-001`のvehicle/ground exact rolling hashは
`11334217462533280590` / `7893383440479344794`である。MAVLink queue high-waterは
1 frame/35 byteで、queue drop、CRC error、部分frame配送、制御byte漏れ、hash mismatch、
action retryは0だった。`ST-MAV-PHASE-001`は連続35-byte uplinkを維持したまま
全1000位相を通し、各位相のframe count/hash、固定32-byte write、従来180 ms lower bound、
300 ms admission windowを照合した。

時間量子の精密診断用ID `ST-MAV-001-Q1`はCTest外で10000周期を実行し、
heartbeat 49995、最大gap 1870 ms、GRANT/DONE 10000/10000、上記と同一hash、
drop/partial/retry 0でPASSした。現行canonical証拠は
`runs/ST-MAV-001/summary.json`と
`runs/diagnostics/ST-MAV-001-Q1/summary.json`にあり、Q1は現行CTest登録161件へ含めない。
両summaryの`reproduce`は実行可能ファイルを含む次の形式である。

```powershell
.\build\host\tests\host\vc_lora_host_tests.exe --test-case=ST-MAV-001 --seed=20260817 --output-dir=runs/ST-MAV-001 --trace=runs/ST-MAV-001/trace.csv
.\build\host\tests\host\vc_lora_host_tests.exe --test-case=ST-MAV-001-Q1 --seed=20260817 --output-dir=runs/diagnostics/ST-MAV-001-Q1 --trace=runs/diagnostics/ST-MAV-001-Q1/trace.csv
```

`ST-003`は対象controlを直接破損する方式ではなく、RFの独立random corruptionを3件
注入し、decoderのCRC error 3件、targeted corruption 0件と1:1一致することを確認した。

修正前の5 ms量子2720 msと1 ms量子2690 msは現行結果ではなく、heartbeat tailを
導入するfail-first段階のRED証拠である。前者の実イベント201件固定窓（違反前100＋
marker 1＋違反後100）は
`runs/diagnostics/ST-MAV-001-pre-tail/{summary.json,trace.csv}`、後者は
`runs/diagnostics/archive/ST-MAV-001-Q1-legacy/diagnostic_summary.json`へ分離した。

全8件でcollision、TX gate違反、未許可Ground TX、Vehicle受信窓中TX、制御byte漏れ、
半二重/方向転換/UART buffer破棄、FIFO順序不一致、queue underflow、部分MAVLink配送、
action retryは0だった。online invariantを各stepで検査し、RF履歴/配送待ちhigh-waterは
各1、最終pendingは0だった。通常stressの保持traceは2048 event以下で、
1000/5000/10000周期checkpointでも増加しなかった。

`tools/run_host_sanitizers.ps1`によるClang 22.1.8 ASan+UBSan buildでもPhase 5は
8/8 PASSした。AddressSanitizer report 0、UndefinedBehaviorSanitizer report 0である。
WindowsではLeakSanitizer非対応のため`ASAN_OPTIONS=detect_leaks=0:halt_on_error=1`で
実行しており、OSレベルのleak検査を実施したという意味ではない。

target priority変更前baselineのfresh full ASan+UBSanは161/161成功し、ASan、
DEADLYSIGNAL、UBSan、`runtime error:` markerはいずれも0だった。target priority版も専用の
新規build directoryから167/167成功し、同markerは0だった。normal/sanitizerのJUnit・logは
`runs/validation/VEHICLE-TARGET-PARAM-PRIORITY-AUDIT-002/20260825T121001641Z/`に固定する。

## 基準パラメータ

| 項目 | 値 |
|---|---:|
| Downlink send | 3000 ms |
| Heartbeat tail wait | nominal境界起点1100 ms |
| Uplink guard | 650 ms |
| Uplink admission window | 300 ms（半開区間、whole-frame開始期限） |
| Uplink byte budget | 64 byte/cycle |
| Vehicle receive timeout | 2000 ms |
| Return guard | 650 ms |
| Late terminal wait | timeout起点の絶対1300 ms floor＋raw活動から650 ms延長 |
| AUX High stable | 15 ms |
| E220 sub-packet service floor | 550 ms（AUX high-only/LOW→HIGH共通） |
| AUX LOW return timeout | 2000 ms |
| E220 turnaround | 500 ms |
| Air rate | 19.2 kbps |
| Sub-packet | 32 byte |
| Minimum TX gap lower bound | 180 ms（productionは550 ms floorが支配） |
| UART buffer | 400 byte |

全値は設定構造体から注入でき、試験コード内で変更可能である。

## Phase 2～6の不変条件

正常系では常に次を満たす。

```text
tx_during_rx_window_count == 0
ground_tx_without_valid_grant == 0
control_bytes_leaked_to_local_uart == 0
invalid_crc_state_transition == 0
collision_count == 0
tx_gate_violation == 0
UL_DONE.actual_bytes <= UL_GRANT.max_bytes
1 GRANTにつき上りpayload transactionは最大1回
1 cycleにつきVehicleのGRANTは最大1回
ground_queue_bytes <= 16384
ground_usb_accepted_bytes + ground_usb_dropped_bytes == ground_usb_rx_bytes
RF writeがAcceptedになったbyteだけqueueから消費
ground_payload_order_errors == 0
ground_queue_underflow_count == 0
physical E220 write <= 32 byte
same-node remote service completion gap >= 550 ms
new Ground transaction start < corresponding GRANT admission deadline
post-deadline continuation == same preflight-approved latched descriptor
started transaction DATA + UL_DONE completion <= first Accepted + 2000 ms
96-wire/oversize descriptor prefix bytes == 0
action_retries == 0
partial_mavlink_delivered == 0
mavlink_crc_errors == 0
mavlink_parser_resets == 0
mavlink_queue_drop_frames == 0  # in-capacity traffic
Ground local egress overflow => newest complete frame only is dropped; runtime remains live
Vehicle local egress overflow => fail-closed
PID_TUNING (msgid 194) is filtered only after valid-frame classification
heartbeat_max_gap_ms <= 2500
stress_trace_retained_events <= 2048
stress_rf_retained_transmissions <= 16  # 実測high-waterは1
```

## 決定論と失敗時情報

- 実時間sleepは使用せず、物理仮想時刻を1 ms単位で進める。
- 確率異常はプラットフォーム非依存のxorshift32と記録済みseedを使う。
- `trace.csv`列は
  `time_ms,node,state,cycle_id,event,aux,queue_bytes,radio_tx_bytes,radio_rx_bytes,session_id`
  とする。
- `summary.json`には試験ID、seed、主要カウンタ、最初の失敗条件、
  再現コマンド、PASS/FAIL/XFAILを保存する。

## 制御判定とシミュレータ境界

- RFシミュレータは別渡しの`is_control`フラグを使用せず、送信されたbyte列が
  version 2のexact 32 byteかつ先頭`VCTD`であるかを見て制御/データを分類する。
- `TddLinkDemux`はRF/UART read境界に依存せず、分割された制御候補を保持し、
  データと連結された複数の制御フレームも抽出してローカルUARTへ漏らさない。
- 制御decoderは構造検査後、CRCをversion/typeより先に検査する。したがって、
  CRC不正フレームを未知version/typeとして扱って状態遷移させることはない。
- UART送信時間は115200 bps・8N1相当の10 bit/byteを含めて計算する。
- `uart_buffer_drop_count`、`turnaround_drop_count`、
  `half_duplex_drop_count`を個別に記録する。
- Buffered E220 modelはUART約3 msの後に550 msのair serviceを表す。production floorでは
  最大64 byteが短時間共存するが累積せず、remote completion間隔550/551 ms、反転quiet
  654 ms（要求500 ms以上）を確認する。550 msはremote service spacing floorであり、
  writeの瞬間に内部bufferが完全空であることは保証しない。
- 受信区間中は受信側AUXをLowとして扱い、受信区間と自身のTX区間が少しでも
  重なれば半二重破棄する。
- 透過streamの分割・連結demuxに加え、dataの`0x56`と`0x7D`をescapeする。
  これにより通常データ内の`VCTD`は制御に誤認されない。制御frameはrawの
  ままで、demuxはescape済みdataとraw制御を分離する。RF再順序化と実機
  E220の詳細なAUX波形は現段階の対象外である。
- escape modeでwire上のraw `V`は制御候補の開始とみなし、後続の`C/T/D`または
  CRCが破損していても32 byte全体をquarantineする。decode失敗の制御候補も
  MAVLink endpointへ流さない。

## 固定ハードウェア条件

Phase 1～6のhost coreとproduction adapterは次の条件を変更していない。

- E220: `D0=M0`, `D1=M1`, `D2=XIAO TX -> E220 RXD`,
  `D3=XIAO RX <- E220 TXD`, `D8=AUX`
- Pixhawk: `D6=XIAO TX -> Pixhawk RX`, `D7=XIAO RX <- Pixhawk TX`
- Pixhawk/GCS UART: 57600 bps、8N1
- E220 UART: 115200 bps、8N1
- E220プロファイル: `00 00 E5 C3 46 00 00 00`
- chunk 32 byte、partial flush 50 ms、minimum TX gap 180 ms（下限）、
  E220 remote service floor 550 ms

`partial_flush_ms=50`は旧raw stagingで32 byte未満を保持できる最大待ちを固定する互換定数で、
Phase 6 production pathのtimer判断には未使用である。frame-aware adapterはCRC合格済み完全frameだけをqueueし、active frame tailを別の
50 ms timerで保持せず即時eligibleにする。したがってlocal staging待ちは0 msで50 ms以内だが、
TDD admission windowと550 ms service-floor pacingによる無線送信待ちはこの値に含めない。

## Phase 6判定（R17履歴）

R17 canonicalのhost全体は177 normal PASS＋2 expected negative＋0 unexpected FAIL（CTest runner 179/179）である。
80 msgid、scheduler、fixed Ground/local adapter、NVS identity、64-bit time、E220 AUX/write、
550 ms service floor、started-transaction watchdog、profile fail-closeを実装・試験済みである。
`runs/e220_service_floor_vehicle_transport_green/summary.json`はexact32に加えて45-byte/64-wireを
実Vehicle controller/demux/quarantineへ通したbuffered transport GREEN（atomic commit 1、受信期限余裕
341 ms、partial/discard/outside/timeout/collision/loss 0）、
`runs/e220_started_tx_bounded_green/summary.json`はwatchdog GREENの証拠である。従来の
binary size/hashはservice-floor変更前の履歴buildであり、R17 canonical sourceのcompile/書込み
証拠に使わない。R17は4 Arduino sketchへ同期し、production Vehicle/Groundのclean compileまで
PASSしたが、upload・COMアクセス・Mission Planner実機再試験は実施していない。

- **Software / preflight: GO**
- **Deployment: NO-GO**

旧service-floor baselineのbinaryは作成・書込み済みである。compile正本は
`runs/validation/final_production_compile_20260823T192757014Z/`、upload正本は
`runs/hil/PROD-V2-PACING-HB-UPLOAD-001/20260823T194053048Z/`である。ただしR17
canonicalのdeployment証拠ではない。R17を書込み後、両roleの完全電源再投入、
parameter往復とHeartbeat cadenceの実機確認までNO-GOとする。
変更前v2 production HILのvalid request msg20=1、Heartbeat最大gap4098.309 msはfail-first比較証拠である。
未解決境界はD6→flight-controller受信/応答である。read-only parameter証拠はSERIAL1/2_PROTOCOL=2、
BAUD=57、OPTIONS=0、MAV1/2_OPTIONS=0、BRD_SER1/2_RTSCTS=2 (Auto)であり、要求値0との差を次に切り分ける。
証拠は`runs/hil/E2E-MAV-PARAM-VALID-PRODUCTION-001/20260818T205113762Z-ground-com6/judgment.json`、
`pixhawk_serial_parameters_readonly.json`、`runs/phase6_arduino_compile/flash_evidence.json`である。

## R19 read-only CDC bootstrap（2026-10-03現行追補）

2026-09-30の2回のdiagnostic HILでは、runnerがstrict read-onlyである状態で
Vehicle／Ground両COMが0 byteとなった。native HWCDCのcached connectionが最初の
host IN pickupまたはOUT RXまでfalseである一方、旧診断publisherはそのconnectionを
最初のframe enqueue条件にしていたため、offline model上では共通のbootstrap deadlockになった。

Section 26旧candidate世代のホスト契約は次を固定した。後続のfalse-SOF訂正は本節末尾を正とする。

- Vehicle cold-start bootstrap: 11/11 PASS
- Ground cold-start bootstrap: 13/13 PASS
- exact 63-byte R19A/R19Fをclean empty boundaryへall-or-zeroで公開する
- ISRはpublication fence解放後に最大32 bytesずつdrainする
- epoch、BUS_RESET、quarantine、plug presenceをenqueue前後に確認する
- debug writerとbootstrap writerを同一mux reservationで直列化する
- endpoint-ready前はdeadlineを開始せず、Ground reservationをinactiveに保つ
- BUS_RESET後は同一wire image／MAVLink sequenceを新epochで再armする
- macro-off、`writeTxChecked()`、`operator bool()`、product routeを変更しない

`FW-HWCDC-TX-INTEGRITY-001`は33 checksを持ち、うち次の7件をdiagnostic candidateの
sealed evidenceとして必須にする。

1. `diagnostic_bootstrap_api_macro_scoped`
2. `diagnostic_bootstrap_exact_63_byte_cold_start_only`
3. `diagnostic_bootstrap_requires_clean_empty_boundary`
4. `diagnostic_bootstrap_all_or_zero_publication_fence`
5. `diagnostic_bootstrap_rechecks_epoch_reset_and_presence`
6. `diagnostic_bootstrap_isr_fence_before_ring_and_fifo`
7. `diagnostic_bootstrap_serializes_debug_writer`

installer契約はexact upstream／exact prior-canonical pairだけを受け入れ、unknown、mixed、
不完全backup、改竄archiveを拒否する。candidate verifierは上記7 assertionの欠落、false、
summary hash不一致を拒否する。

Section 26旧candidate sourceの独立normal CTestは301/301 PASSである。Clang 22.1.8
ASan＋UBSanのfresh full suiteも301/301 PASS、failed/skipped 0、ASan/UBSan report 0だった。
その旧実行時に記録したsummary SHA-256は
`C9830AC05D7838DC5F7513E07E736226FAAF43903B6C9C38AC3169C02242BC9D`である。
`runs/host_full_sanitizer_summary.json`はlatest-run正本であり、現在ファイルは後段のfalse-SOF修正版から
再生成済みなので、現行hashは後段のfresh candidate記録を正とする。

これはsoftware boundaryの証明であり、Windows native CDCの物理成功を主張しない。本節の
`20261003T081053916Z-1a760fe3`は当時未flashだったが、後続の実機試験で使用済みである。
受入不可、Deployment不可という制約は変わらない。

## R19 read-only CDC bootstrap物理再評価（2026-10-03現行追補）

一回限定許可でartifact `20261003T081053916Z-1a760fe3`を書込み、40秒dual-COM取得を行った。
run `20261003T083253345Z-5fc0094a`はVehicle／Groundとも`raw_bytes=0`、完全frame 0、
R19A／R19F 0で、`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`だった。最大service gapはVehicle
`66,228 us`、Ground `62,095 us`、serial write 0、parser clean、cleanup PASSである。従って前節の
cached-connection bootstrap bugは実在しても、物理0 byteの唯一または十分な原因ではない。
capture正本は
[`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T083253345Z-5fc0094a/summary.json)である。

capture後はVehicle application
`9157311590ACA76326FA91E6BE1C2C0BF07CCD6B4D65CFFB778C3B61C97D0E52`、Ground application
`30EE08F194DE279186B6603F019D81C2C1B2BE5E473DB318D21DD171E4F0E8D5`のaccepted R18へ初回で復旧し、
readbackと再列挙がPASSした。現在の実機はR18で、当該許可は消費済み、R19受入・Deploymentは未許可である。

次のhost契約をtest-firstで追加した。

- `Serial.isPlugged()==false`でも、reset／quarantine／epochとclean empty boundaryを満たせばexact 63-byte
  bootstrapをall-or-zeroでqueueできる
- endpoint-ready判定とSOF由来raw presenceを分離し、bridgeはfalse-SOFだけを理由にreturnしない
- postcheck成功後はpublication fence解除、`IN_EMPTY` enable、explicit
  `usb_serial_jtag_ll_txfifo_flush()`の順で最初のIN transactionをkickする
- permitted ISRが観測したcached `connected`を診断flushのhost-pickup witnessとして使い、false SOF sample
  だけで成功済みendpointを無効化しない
- no-host、BUS_RESET、epoch変化、dirty ring／stash／FIFOでは物理完了を主張しない
- macro-off production、R18、normal `writeTxChecked()`、TDD、UART、E220、MAVLink、parameter順序は不変

false-SOF cold-startを固定したVehicle／Ground隔離試験は修正前RED、修正後GREENである。runnerには
live captureで欠けていた`final_seal.sha256` sidecarを必須化し、契約試験もRED→GREENとした。

このsourceの資格確認は**offline-only**で実施し、旧candidateへ遡及適用しない。fresh normal 301/301、
ASan＋UBSan 301/301、HWCDC semantic 33/33、installer `-CheckOnly`、両role compile、独立verifierを
PASSし、fresh diagnostic candidate `20261003T091702033Z-e3aa5200`として封印した。

現行sanitizer正本は
[`host_full_sanitizer_summary.json`](runs/host_full_sanitizer_summary.json)で、SHA-256は
`17376F41B827A562EB4C65D44FC5DDB6DA229FF1D366B23FD8D6A4ECBB36004C`である。

- latest SHA-256: `B8F1E11C596F000E3639A8A344D072EB22679F1C09101C84A80FF35AB9C0BE81`
- candidate manifest SHA-256: `0836246D655F1F03CF391DC0C7BC1D74C858A4F508ED12F5F33842825318515A`
- final seal SHA-256: `A2D1433442E9A6BD4D0A242E4F491C46F9898E405FB3FF84E1A1C8DB40254B71`
- Vehicle application SHA-256: `9B4D559C105EDB5A12F657FAC9AC0F631E0EE1379B29A6C86A9A8FF04E19A2CE`
- Ground application SHA-256: `D191D50F38A5CBD87F1995DD83754EB727CE68EEB8E92EC4D7C6FBA8FEF619EF`
- hardware interaction false、opened COM 0、flash false
- `acceptance_eligible=false`、`acceptance_authorized=false`、`deployment_authorized=false`

candidate manifestのhardware interaction false、opened COM 0、flash falseはpackage生成時の事実である。
後続の実機操作は次節の独立したinstall／capture／rollback証跡で管理する。

## false-SOF／ZLP candidate物理結果（2026-10-03）

一回限定許可でartifact `20261003T091702033Z-e3aa5200`をapplication-onlyで両roleへ書き込み、run
`20261003T094504443Z-32368ca4`として40秒dual-COM read-only取得を行った。installは
`PASS_R19_DIAGNOSTIC_INSTALLED_HIL_ONLY`だったが、captureはVehicle／Groundとも0 byte、0 frame、
R19A／R19F 0の`FAIL_NO_DIAGNOSTIC_BEACON / NO_BEACON`だった。最大service gapはVehicle `98,532 us`、
Ground `50,185 us`、serial write 0、cleanup PASSである。

- install: [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-install/flash_record.json)
- capture: [`summary.json`](runs/hil/R19-RUNTIME-FAIL-DIAGNOSTIC-HIL-001/20261003T094504443Z-32368ca4/summary.json)
- rollback: [`flash_record.json`](runs/validation/R19-RUNTIME-FAIL-DIAGNOSTIC-APP-FLASH-HIL-001/20261003T094504443Z-32368ca4-rollback/flash_record.json)

false-SOF／explicit ZLP kick契約はhost上で成立しているが、実機0 byteを解消する十分な修正ではない。
0 byteのためparser、RF、TDDの成否は証明していない。取得後は両roleをaccepted R18へ初回で復旧し、
readbackと再列挙がPASSした。直近許可は消費済みで、R19受入・Deploymentは未許可である。

次のhost変更では、common early-boot、diagnostic publisher、HWCDC ring／FIFO、USB INの各stageを
CDC出力自体に依存しない証拠または最小CDC canaryで分離する。新しいtest-first修正、full suite、sanitizer、
semantic、compile、candidate封印が完了するまで、同artifactを再HILへ使用しない。

## USB CDC direct-payload bootstrap（2026-10-10 offline追補）

Section 31.16の実機証拠では、Vehicle／Groundとも40秒CDC captureが0 byteである一方、
JTAG runtime-stageは両roleとも`WriteAccepted`到達後に`FlushFailed (0x54520010)`を記録した。
この境界と整合するsoftware liveness gapとして、完全63-byte frameをsoftware ringへ受理した後、
最初の実payload FIFO投入がempty-FIFO/ZLP要求と後続`IN_EMPTY`に依存する経路を分離した。
これは実機未確認のoffline仮説であり、0 byteの根本原因確定又は解消済みを意味しない。

新しいRED assertion
`diagnostic_bootstrap_payload_primes_fifo_before_flush`は旧実装だけでfalseとなった。GREEN実装は
診断macro限定で、postcheck後にBYTEBUFから最大32 byteを同一publication fence／mux下で取り出し、
BUS_RESETをFIFO write前後に再検査してreal payloadを直接FIFOへprimeする。short write suffixは既存の
固定64-byte stashへ保持し、`tx_payload_in_flight`を設定してから`IN_EMPTY`をenableし`wr_done`する。
zero write又はraced resetはfail-closedとし、後者でpossibly-written FIFOをquarantineする。
通常の`writeTxChecked()`、`flushTxComplete()`成功predicate、UART／TDD／E220設定は変更しない。

現行`FW-HWCDC-TX-INTEGRITY-001`は35/35 PASSである。diagnostic candidate manifestが要求する
semantic subsetは、bootstrap固有8件と
`diagnostic_connected_requires_payload_pickup_witness`の合計9件である。欠落、false、重複、summary改竄を
verifierは拒否する。通常host CTestとfresh Clang 22.1.8 ASan＋UBSanはともに303/303 PASS、
sanitizer report 0である。

fresh offline candidateは`20261010T090523384Z-93c6076d`で、Vehicle→Ground順にcompileし、独立verifierに
合格した。manifest SHA-256は
`C2E06148A0F274FE13D43FA2635A831BA06F5A7145A714C81A28B04B03ABBDCD`、final seal SHA-256は
`390ACB1A5A0FBC64F194A4F9B1E63144E3F16B0C80321C6999B94603E7E78459`である。build時のhardware
interaction、COM open、upload、flashは全て0で、accepted R18 default sketchesは同一tree hashのまま維持した。
実機HIL、R19 acceptance、Deploymentは未許可・未合格である。
