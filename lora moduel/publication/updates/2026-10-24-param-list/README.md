# R19パラメータ取得要求と高速転送停止の評価

2026年10月24日JST更新。最新試験では、取得要求を1回送信しましたが、要求起点30秒時点・40秒の保存生データとも **0／932件** でした。Groundは初回Heartbeatを正常に公開した後、パラメータ取得用の高速転送処理で安全停止しました。試験後は両機をaccepted R18へ復旧しています。

## 同じ候補で異なる停止段階を確認

診断候補は3回とも `20261023T120117864Z-c22a4e7c` です。試験中にファームウェア・SDK・UART・RF・TDD設定は変更していません。開始時刻は書込みを含む全体手順の開始で、40秒は通信測定部分です。

| 全体手順開始 JST | 取得要求 | 製品Heartbeat | AUX | 結果 |
|---|---|---|---|---|
| 10月24日 09:40:54 | 0回 | 0件 | Ground fault 5 | 診断ARM前にAUX復帰待ちで停止。取得はNOT_ATTEMPTED |
| 10月24日 10:40:15 | なし | 保存生データ39件、最大間隔2,066.3112 ms | 両機fault 0 | Heartbeat単独確認。932件取得の評価ではない |
| 10月24日 13:09:06 | 1回、14 byteをPC側APIが受付 | 1件 | 両機fault 0 | 取得要求後にGround高速adapterが停止。取得0／932件 |

根拠は[最初のAUX停止](evidence/pre_arm_aux/summary.json)、[Heartbeat単独試験](evidence/heartbeat_only/summary.json)、[最新の取得試験](evidence/param_attempt/summary.json)です。全手順で記録取得とR18復旧を完了しました。親処理のPASSはその手順完遂を示し、製品通信やパラメータ取得の合格ではありません。

## 最新の取得試験

全体手順は13:09:06から13:12:18 JST、通信測定は40.0025686秒でした。`PARAM_REQUEST_LIST #21` は最大1回とし、再要求・無断延長は行っていません。14 byteのPC側API受付は、無線・Vehicle・Pixhawkへの要求到達を証明するものではありません。

[30秒時点の932件台帳](evidence/param_attempt/param_list_30s.json)は、要求書込み開始を起点として確定保存されています。取得0件、未取得indexは0〜931です。保存生データ全体の独立再解析と実際の台帳処理の再実行でも、`PARAM_VALUE #22` は0件でした。最終集計欄自体は受信済みデータ範囲の集計で、独立した「40秒SLA確定台帳」とは区別します。[取得台帳の独立評価](evidence/param_attempt/parameter_review.json)

Vehicleは2,674 byte・43個、Groundは2,698 byte・44個のCRC正常フレームを保存しました。CRC異常・ノイズ・末尾部分フレームは0ですが、取得0件を「全通信error 0・取得成功」とは扱いません。Groundの39個のR19F通知は同じ初回停止記録の繰返しで、39回の独立故障ではありません。

## 確認した停止点と未確定の原因

Groundの初回製品Heartbeatは450 µsでUSB完了条件を満たし、両機のAUX faultは0でした。その後、凍結ソースの [vc_lora_phase6_bridge.hpp](source_snapshot/firmware/phase6/vc_lora_phase6_bridge.hpp) の2299行で、`r19_ground_adapter->tick(now_ms)` が `NoAction` 以外を返し、安全停止が固定記録されています。記録時刻はGround MCU時計の14,412 msです。今回の取得停止は、過去の診断ARM前AUX停止や初回製品USB106 ms超過とは別の段階です。[機器記録の評価](evidence/param_attempt/device_review.json)

PC書込みAPI復帰から最初のR19Fフレーム読取り完了までは501.7386 msでした。コードの `AwaitFreshGrant` 500 ms期限と整合するため有力な仮説ですが、停止時のowner／coordinator状態・`last_error`・MCU要求開始時刻が未記録で、詳細原因は確定していません。このPC時間差をMCUの期限超過時間そのものとは扱いません。次の調査対象は、高速転送への切替からGrant引継ぎまでの内部状態です。

後続の診断USB失敗や、標準UART経路だけの受付カウンタから、全高速RF送信の有無・停止原因を断定しません。

## AUXと診断USBの切分け

09:40の試験ではAUXのLOW→HIGH観測が約5.045秒で、2秒の安全停止条件に達しました。一方、10:40の試験では535.099 msでHIGHを観測し、AUX停止なしで製品Heartbeatを39件受信しています。異常が1回出なかっただけで解消済みとはせず、物理波形・最初の32 byteの内容・E220内部送受信状態の確定には追加記録が必要です。[AUXとUSBの比較調査](evidence/aux_usb_cause/summary.json)

10:40のGroundには初回診断USBの31 byte待機記録がある一方、その後の製品Heartbeatは成立しています。この初回記録だけをAUX停止や恒久的な製品停止の十分原因とは扱えません。「31 byte」はソフトウェア送信待ち領域の値で、CRC末尾31 byteの欠落や物理FIFO内31 byteを意味しません。

同試験の速報台帳は38件ですが、測定終了10.7009 ms前に受信した39件目が保存生データに存在します。これは通信欠落ではなく測定側の末尾集計漏れです。最大受信間隔2,066.3112 msは保存生データ再解析による値で、当該40秒内の隣接Heartbeat間隔に限ります。集計処理の修正は未実装です。[生データと台帳の照合](evidence/heartbeat_only/capture_review.json)

## 測定ツールの追加とオフライン検証

取得要求1回・932件台帳・要求起点30秒の進捗確定保存を、明示的な `ParamListDiagnostics` オプションとして実装しました。既定では無効で、読取り休止比較との併用・失敗後の自動再要求は許可しません。前提条件を満たさず要求0回ならNOT_ATTEMPTEDとし、932個の応答喪失とは判定しません。

新規試験は台帳47・capture統合65・outer契約49の計161チェックをPowerShell 5.1と7で合格しています。全体試験は初回399／401件で2件失敗し、互換性修正後の最終一括試験で **401／401件合格** を確認しました。既存失敗試験の削除・緩和はしていません。Vehicle→Groundの通常Arduinoコンパイルも合格していますが、生成物をaccepted R18として置き換えたものではありません。[検証原本](evidence/offline_param_instrumentation/summary.json)・[最終試験ログ](evidence/offline_param_instrumentation/host_final.log)・[変更差分](evidence/offline_param_instrumentation/changes_final.patch)

今回の公開操作ではソースの修正・実機操作を行わず、関連ソースと記録を選別コピーしました。公開スナップショットでも純粋な台帳試験47件をPowerShell 5.1と7で各47件合格し、原本hash・リンク・JSON・構文・秘密情報を検査しました。これは元ワークスペースの401件試験とは別の結果です。[公開時検証](validation/summary.json)

## 復旧状態と残る受入条件

両機ともaccepted R18への復旧と機器側digest照合を確認済みです。USB完了106 ms、AUX timeout 2,000 ms、HIGH安定15 ms、既存UART・RF・TDD条件は維持しています。R19受入・Deploymentは未許可です。

最終受入には、同一runで **932／932件・30秒以内・Heartbeat最大2,500 ms以下・全error 0** の同時成立が必要です。Heartbeat単独試験の合格値を、取得中の動作や全通信状態へ転用しません。

## 公開範囲

- [source_inventory.json](source_inventory.json)は、原本との相対パス・SHA256・byte数を記録しています。原本は変更していません。
- `source_snapshot/` は測定ツール・関連試験と停止点の確認用ソースです。直下の古い製品ソースや[前回の公開資料](../2026-10-24/README.md)は置き換えていません。
- 個体識別を含む書込み・事前確認・親実行ツール3本は新スナップショットから省略しました。変更は差分、検証時のhashは原本summaryに残しています。21ツールを照合した実機試験と、この選別公開物のファイル数は異なります。
- application BIN・ELF・MAP・EXE、APIキー、実行許可ファイル、PnP原本、operator確認全文、親実行ログは追加公開していません。選別JSON内のローカルパスや非同梱ファイルへの参照は来歴であり、公開コピーだけで全試験を再現・実機書込みできる保証はありません。
- GitHub上の記録は次の実機試験を許可するものではありません。通常製品通信はMission PlannerとGroundのCOM6が直接行い、PowerShellやJevを中継に使いません。
