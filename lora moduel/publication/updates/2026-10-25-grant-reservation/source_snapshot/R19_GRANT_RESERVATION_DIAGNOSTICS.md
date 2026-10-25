# R19 診断用Grant予約と実機評価手順

更新日: 2026-10-25 JST

両XIAOのUSBを同じPCで監視する診断試験に限り、Vehicleが実際に発行した次のGrantを一時保持し、Groundで完全な取得要求を受け付けた後に送信する。無線だけで任意の時点から高速開始できる製品用予約プロトコルとは区別する。

## 維持する通信条件

Groundの完全なPARAM_REQUEST_LIST受付から新しいGrant受信までは500 ms以内、Vehicleの同じGrantの物理送信完了から正当な完全VCBN受付までも500 ms以内とする。Groundの100 ms guard、製品Heartbeatの106 ms公開条件、元の要求時刻からの28秒leaseと30秒取得条件は変更しない。

ピン、Pixhawkの57600 bps、E220 UARTの115200 bps、air 19.2 kbps、32-byte chunk、550 msのservice floorとAUX HIGH連続15 msも維持する。AUX HIGHだけを最終RF到達の証明にはしない。

## 開始と送信完了の順序

1. 両機の候補・役割・USB epochを照合する。両側のUSBローカル時刻応答、Ground READY／ARM、その後の主機体Heartbeatを確認する。
2. Groundで実際に受理した標準Grantをbaselineとして取得する。Heartbeatや予定周期からbaselineを作らない。
3. Vehicleの標準TDDが実際に発行したSendGrantに対して、本物のwriter tokenとgenerationを取得する。まだUARTへ書かず、同じactionを最大750 msだけ保持する。保持中もAUX観測と期限判定を継続し、Heartbeatやepoch等で条件を失えば停止する。
4. PCが両機のboot、epoch、reader session、slot nonce、Grant session／cycle、writer token／generationを結び付ける。GroundのBound応答前に取得要求を送らない。
5. 完全な取得要求を最大1回送る。Groundが既存adapterでHeldとなった実時刻を元の要求時刻に固定する。PCは実際のGroundHeld応答後にだけ、Vehicleへ保持したGrantの送信を指示する。
6. Vehicleは同じwriter leaseとactionを1回だけ使用する。Groundは実際の新Grant受信を元の要求から500 ms以内で検査する。
7. Vehicleは既存の物理送信完了処理が成立した時刻Pを保存し、TailReadyを公開する。PCがこれを照合してGroundへ渡す。Groundは元のGrant受信後100 msに加え、TailPermitのローカル受信後100 msも満たしてからVCBNを送る。
8. Vehicleで完全かつ正当なVCBNが受理された時刻Qを保存し、同じMCU時計で0≦Q−P≦500 msを検査する。その後の交渉、bulk、終端確認も既存の条件で評価する。

USBの通知遅延や無線の遅延により条件を満たせない場合は失敗となる。この手順は、将来の通信時間の上限や高速開始の成功を保証するものではない。異なるMCUの時計を直接引き算しない。

## 記録と測定区間

準備は最大15秒とし、その後に固定40秒の測定区間を設ける。準備不成立時は取得要求を送らず、原因記録のための受信のみを続ける。取得要求の部分書込み・例外・期限切れでも再要求せず、元の要求時刻は移動しない。

連続readerが取得した全rawを保存し、準備と測定の区間別raw、境界offset、PC読取り時刻、各制御OUTの試行・完了を別に残す。1回のPC読取りが区間境界をまたぐ場合、そのbyte単位の物理到着時刻は不明として扱う。

新しい512-byte固定JTAG記録 `vc_lora_r19_grant_reservation_record` は、既存記録を変更せず追加する。schema 1、magic `0x52313952`、boot／epoch／tupleと12件のイベント履歴を保持し、初回失敗で全体を固定する。reader v10は両機それぞれ10記録を2回ずつ読み、rawから独立に再照合する。旧reader v8／v9は既存用途のまま残す。

readerによる記録形式・raw一致の検証だけでは、予約プロトコル全体の成立を証明しない。今回の実機評価ではPC制御履歴と両機のboot／epoch／同一tupleを照合し、各500 ms条件はそれぞれ同一MCU時計で手動評価する。記録欠落、初回失敗による固定、対応関係が不明な場合は未証明とする。

新しい私設制御はMAVLink2 STATUSTEXT内の66-byteフレームで、sys249、要求component197、応答component198を使用する。CRCとnonceは診断の照合用であり、PCの認証ではない。これらのフレームをPixhawkやRF製品経路へ転送しない。製品運用でPowerShellやdual-COMの予約制御を必須にする仕様ではない。

## 有効化と受入判定

機能は既定OFFの `VC_LORA_R19_GRANT_RESERVATION_DIAGNOSTICS` と測定側の `GrantReservationDiagnostics` で明示的に選ぶ。完全なGrant診断とExplicitHostArmを前提とし、専用candidate・能力契約・26ツールの照合が一致した場合だけ使用する。旧candidateや机上のslot計画を予約成立の代用にしない。

実機試験は一回限定許可、安全6項目、電源OFFと再接続の確認後に実施し、終了時はaccepted R18を両機へ復旧してdigestを照合する。準備15秒を追加した今回の範囲は再接続案内で確認する。

高速成功には、実際の両500 ms条件、交渉完了、bulkと終端確認、および同一runの932/932件・30秒以内・Heartbeat最大2500 ms以下・全error 0が必要である。診断取得やR18復旧だけの成功、低速への切替え、Heartbeatの件数だけを高速成功とはしない。

## 検証結果の入口

[今回の検証summary](runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/summary.json)に、失敗試験と修正後評価、両機ビルド、候補照合、実機試験の実施有無を保存する。実機の通信改善は、当該実測結果で判定する。

準備時点の回帰試験は447/447合格（825.01秒）。候補 `20261024T215821978Z-c1982cbd` はVehicle→Groundの順でビルドし、実際の生成物を用いる最終照合にも合格した。当時の26ツール・83正本ファイル、172件の候補保存物、両役割のBINとaccepted R18保存物も独立照合した。この事前検証は、次節の操作記録関数の不具合を検出できておらず、実機成功の証明ではない。

記録上の制約として、測定ツールの初期統合時の変更前差分の一部が保存されていない。現行26ツール・正本83ファイルのSHA照合と現行一式は保存するが、これを失われた初期差分の代替証明とはしない。後続の照合修正は変更前の実ファイルと差分を保存して検証する。この制約も実機再接続案内で明示する。

## 2026年10月25日の実機手順の結果

12:39～12:40 JSTの一回限定手順は `FAIL_ROLLBACK_UNPROVEN_POWER_OFF_REQUIRED` で終了した。両機のUSB-JTAG接続事前確認は合格したが、その後の機器ID確認を記録する `Invoke-ToolOperation` 内で、別関数にしか設定されない `$modeHandoff` を参照して停止した。予約診断の保存情報を誤った関数へ組み込んだことが直接原因であり、500 ms条件やRF通信の評価結果ではない。

実際に実行されたのは、両機のJTAG transport初期化と、Vehicle4回／Ground3回の機器ID確認である。ID確認ではCOM接続・RAM stub投入・RTS resetが行われた。flash書込み・照合の操作記録は0件で、40秒測定、PARAM要求、内部記録の読取りには進んでいない。集約操作リストが空なのは、個別の成功記録を書いた後、集約リストへ追加する前に例外が出たためであり、「機器操作0」の証拠にしてはならない。

もう一つの不具合は失敗記録の検証にある。UTF8で保存した日本語エラー文字列をWindows PowerShell 5.1の既定文字コードで読み戻し、保存終了処理が二次的に失敗した。保存されたUTF8 JSON自体は明示的なUTF8読取りで回収可能だが、成功した封印記録には昇格させない。

12:39の手順ではR18復旧も同じ操作記録の不具合で停止し、復旧のdigest照合は未証明だった。起動した子処理5件の終了と両JTAG処理のshutdownを確認し、利用者の全USB・外部電源OFFをPC側でも12:42 JSTに確認した。この許可は使用済みとして終了し、その後の修正と新しい許可による再試験は下節に分けて記録する。

[実機手順の保存結果](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261025T033913241Z-grant-reservation-param-once/summary.json)と[独立監査](runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/postfailure_independent_review_20261025T033913241Z.json)に、実施操作と未評価項目を残す。

## 試験ツールのオフライン修正

予約診断の保存情報を個別の操作記録から取り除き、handoff読取り後の集約・封印関数でだけ追加するよう修正した。日本語の失敗記録とhandoffはUTF8を明示して読み戻す。失敗時に「測定へ進む」という案内で電源OFF指示を上書きせず、集約記録・内部の許可情報・封印の範囲と次の操作を一致させる。書込み前の機器ID・厳密な引数・digest・排他条件は緩和していない。

実際の操作記録関数と封印関数を用いる失敗試験を追加し、修正前のエラーを再現してから修正した。88項目の境界試験と独立402項目の操作記録試験が、PowerShell 5.1／7でそれぞれ合格した。外部機器呼出しは無害な代用品に置き換えており、実機の書込み成功を証明する試験ではない。追加2試験を含む全449/449件も合格（618.22秒）し、今回の誤った保存経路を通る条件まで回帰試験へ含めた。

実行用26ツールの変更はflashツールと親のSHAピンの2本である。83ファームソース、封印済み候補、失敗した実機手順の記録は変更していない。新しい26ツール照合表v5と、別名の実行準備pin `137AF62F23CB86312C25DA7C0334E1233113BCFF13F6CFA36330DAA5AAE97DED` をファイルのみで検証し、独立確認も完了した。旧pinと使用済みdispatch記録はそのまま保存している。

この修正後、利用者から新たな一回限定許可、安全6項目、電源OFFと再接続の確認を受け、次節の再試験を1回実施した。旧許可・旧pin・旧失敗記録の再使用はしていない。

## 2026年10月25日13時35分の再試験結果

13:35～13:38 JSTに同じ候補の書込み、取得要求1回を含む40秒測定、両機の内部記録取得、accepted R18への復旧を実施した。両機のR18書込みと別途digest照合は合格し、JTAG終了処理は各CPUのrunningとshutdownを確認した。現在は両機ともaccepted R18へ復旧済みで、この試験許可は使用済みである。

| 確認点 | 今回の結果 |
|---|---|
| PARAM_REQUEST_LIST | 完全な14 byteを1回送信。Groundの実要求保持を記録 |
| パラメータ | 30秒時点0/932件、測定終了時0/932件 |
| Ground READYとARM | READY公開と機器側ARM受理を内部記録で確認 |
| 両機の時刻応答 | PCが両方を照合。ただしPCとMCUの時計の同一視はしない |
| 製品Heartbeat | PCで合計12件、うち40秒測定内は1件。Groundの初回21 byteは472 µsでUSB完了 |
| AUX | 両機ともfault 0。物理波形の連続測定ではない |
| 高速転送 | TailReady未受信、交渉・bulk未開始。成功は未証明 |
| 内部記録 | 各20 raw、両機計40 rawのサイズ・SHA・同一2回読取りが一致 |

### Vehicleの予約停止とGroundの期限超過

同一Vehicle時計で、Grant cycle 3の予約成立は39,202 ms、相手機器との結合は39,257 ms、初回の予約失敗は39,356 msだった。予約から154 ms後に `ExternalFault / detail 13` で停止し、予約したGrantのUART受付・送信完了は記録されていない。前のcycle 0～2にはUART受付と送信完了が記録されており、予約したcycle 3とは分けて扱う。

PCの同一時計とCRC照合済みrawでは、Vehicleのこの失敗通知の最終byteはPARAM要求の送信開始より80.4178 ms前、Vehicleへの解放指示より171.4479 ms前に既に読み取られていた。従って「PARAMを送ったことでVehicleが初めて停止した」とは説明できない。測定ツールはこの失敗通知を取得済みなのに要求送信へ進んでおり、PARAM要求とReleaseVehicleの送信前の中止判定も修正対象である。PCの解放指示の書込み受付は、Vehicle側で解放が成立した証拠ではない。

Groundは元の要求受付26,016 msから26,517 msまで501 ms待ち、ownerとcoordinatorの両方に `GrantDeadlineExceeded` を記録した。この局所停止原因は確定した。一方、Vehicleはそれ以前に予約を保持できなくなっているため、500 msを延ばして解決したと扱わない。

Vehicleのdetail 13は、Heartbeat優先、AUX読取り、writer lease不一致、無線処理中など複数の条件を一つにまとめた停止である。どの条件が最初に成立したかは固定記録にない。コード上では、新しいHeartbeatが保持中に届くと、Heartbeat期限2,500 msに対する予約余裕5,050 msの比較で直ちに優先扱いとなり、通常のTDD処理へ戻らず予約を中止する経路がある。これは今回の154 ms停止を説明できる有力候補だが、実測の単一原因としては未確定である。

### USBと取得判定を分ける

診断USBの初回63-byte受付後に31 byteが待機した記録は、Vehicle起動後2,567 ms、Ground起動後11,558 msに残っている。一方、Groundの初回製品Heartbeatは106 ms以内で公開完了しており、その失敗記録はない。起動時の診断USB失敗を、今回の予約停止や製品USB失敗の直接原因と断定しない。40秒を通したHeartbeat継続と全error 0は合格していない。

親手順の保存結果は `FAIL_STAGE_READ_R18_RESTORED` のままとする。reader v10の各子処理はPASSでraw再照合も合格したが、親の最終schema許可リストがv9までだったため、両機の取得証明を誤って不成立とした。保存済みrawに対するファイルのみの再解析で、この判定漏れを切り分けた。元の実機結果・raw・封印・使用済みpinは変更しない。取得記録を解析できることと、高速通信が成功することは別である。

この判定漏れは、実際の親関数の最終条件を使う失敗試験を追加してから、v10を許可リストへ追加するだけのオフライン修正を行った。最終条件の59項目と、保存済み両機の20 rawを実関数で再照合する109項目が、PS5.1／7でそれぞれ合格した。旧形式v3／v9の受付と、不明形式・44項目の証拠／安全条件違反の拒否も維持する。全449試験の合格は今回の実機開始時点のソースに対する結果であり、この追加修正後に全450試験を再実行したという意味ではない。親ツールのSHAが変わったため、v5照合表と使用済み実行pinは履歴として保持し、次の実機準備で新たに照合する。新たな実機操作は行っていない。

[実機手順の保存結果](runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261025T043509262Z-grant-reservation-param-once-after-flash-metadata-fix/summary.json)、[通信停止とPC時刻の派生解析](runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/reservation_failure_derived_readonly_analysis.json)、[復旧と保存物の独立監査](runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/retrial_restore_artifact_independent_audit_20261025T043509262Z.json)、[親の形式判定の再解析](runs/validation/R19-GRANT-RESERVATION-INTEGRATION-OFFLINE-001/20261025T-fix/post_repaired_hil_stage_gate_analysis.json)を参照する。次回実機操作には新たな一回限定許可と、変更後ツールの再照合が必要である。
