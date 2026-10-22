# R19 AUX観測修正と時刻同期の原因調査

2026年10月23日JSTの進捗更新です。10月22日JST終盤の実機試験で、USB診断待ちによるAUX観測停止の改善と、初回製品HeartbeatのPC正常受信を確認しました。10月23日のオフライン調査では、Vehicle時計応答が未実装なのに測定側が要求する不一致を確定しました。

R19は診断段階です。932件30秒取得と全error 0の同時達成、製品受入、Deploymentは未完了です。今回のGitHub更新では機器への書込み・COM接続・追加実機試験をしていません。

## 実機で確認した進捗

| 項目 | 前回又は条件 | 最新結果 |
|---|---|---|
| Ground記録末尾のAUX未観測区間 | 10,800,911 µs | 4 µs |
| Ground最大GPIO観測間隔 | 通常観測をUSB診断待ちが遮る経路あり | 100,551 µs |
| READYと診断ARM | 過去の未成立段階から改善 | PC READY正常、MCU ARM受理 |
| 初回製品HeartbeatのUSB完了 | 106 ms条件を維持 | 0.471 ms |
| 初回製品HeartbeatのPC検証 | 同一完全フレームを確認 | 一意に一致、CRC正常 |
| 40秒区間のHeartbeat | 最大2,500 ms以下を確認対象とする | CRC正常40件、最大2,100.2658 ms |
| 試験終了処理 | accepted R18復旧が必須 | 両機各1回で書込み・digest照合・再認識 |
| 元ワークスペースの全体試験 | 変更後の回帰 | 371／371 PASS、両機コンパイルPASS |

測定時間は40.0006509秒、Ground 3,693 byte、Vehicle 2,646 byteです。Heartbeat間隔はPC読取り完了時刻の差であり、無線airtimeや保証付きPC–MCU遅延ではありません。

4 µsは、最後に保存されたGPIO採取と最後のloop終了記録の差です。GroundのAUX割込み履歴は68件overflowしており、試験全体の連続した物理波形を保証しません。Vehicleの末尾差は30 µsです。

結果の正本は[実機評価](evidence/live/operator_evaluation.json)、[受信データの定量評価](evidence/live/quantitative_observations.json)、[独立AUX評価](evidence/live/aux_evaluation.json)、[復旧と整合性監査](evidence/live/post_run_integrity.json)です。

## AUX観測停止の原因と修正

GroundのUSB診断フレームが送信境界を所有している間、処理が通常のAUX観測より前にreturnしていました。実際のbridge loopを使うオフライン再現では、10.8秒間にAUXを一度も読まない状態を確認しました。

修正は、診断送信待ち・ALIVE排出待ち・通常処理停止の3か所で、AUXだけを新しく観測するものです。無線完了を消費せず、送信権・RF tail・USB排他を維持します。USB待機関数の内部で連続採取するものではなく、既存の100 ms予算の待機から戻った後に観測します。

失敗試験を先に追加し、5ケース66チェックの修正前15失敗から修正後0失敗を確認しました。同じ10.8秒・108ループでAUX読取りは0回から108回になりました。AUX LOW 2秒の安全停止も維持しています。

[原因再現](evidence/aux_tail_cause/summary.json)、[修正結果](evidence/aux_fix/summary.json)、[差分](evidence/aux_fix/changes.diff)、[全体試験ログ](evidence/aux_fix/full_host_tests_windows_ps51.log)を参照してください。修正結果JSONの末尾に残る「実機の観測間隔は要測定」という文は実機前の段階の記述であり、最新の実測は本更新の実機評価を参照します。原本JSONは変更していません。

ピン割当、UART、E220 profile、TDD、製品USBの106 ms条件は変更していません。

## Vehicle時刻同期失敗の原因

測定ツールはVehicleのCOM3へ28 byteのSyncOnly時計要求を送り、返信を5秒待ちます。しかし候補ファームの時計要求受付・返信処理はGround専用で、VehicleのUSB RXを処理する経路がありません。Vehicleの通常入力はPixhawk UARTです。

実際の候補ソースを用い、同じCRC正常要求をUSB RXへ注入して比較しました。

| オフライン再現 | 6秒後のUSB RX残量 | 時計要求処理 | 時計返信 |
|---|---:|---:|---:|
| Vehicle 600ループ | 28 byte | 0回 | 0件 |
| Ground陽性対照 | 0 byte | 1回 | 1件 |

合計17チェックが合格しました。実機でPCの28 byte書込みがMCU内部へ到達したこと自体を証明するモデルではありませんが、到達しても現Vehicle実装では返信できないことを確認しています。PCの読取りは要求送信より1,242.11 ms早く開始しており、単に読取り開始を早めたり待ち時間を延ばしたりしても、この実装欠落は解消しません。

一つ前の実機試験にも同じ不一致があり、今回のAUX修正で新発した問題ではありません。Vehicle時計要求処理の修正はまだ実装していません。

[原因調査の要約](evidence/sync_cause/summary.json)、[Vehicleの再現結果](evidence/sync_cause/vehicle_sync_cause.json)、[測定側の監査](evidence/sync_cause/runner_workflow_audit.json)、[再現ソース](evidence/sync_cause/repro.cpp)を参照してください。

## 診断USBの再試行記録の意味

保存された `FlushFailed` は、診断フレームのUSB完了確認が失敗した最初の履歴です。Groundの `detail=10029`、Vehicleの `detail=2586` は起動後の観測時刻msであり、欠落byte数や待ち時間ではありません。両機ともその失敗以前のflush成功と、その後の回復完了が記録されています。初回失敗を消さない設計のため、後で成功しても履歴は残ります。

| 条件 | 対象 |
|---|---|
| 106 ms | 製品HeartbeatのUSB公開完了 |
| 500 ms | 診断フレームの完了期限。epoch変化なら期限前にも失敗分岐へ入る |
| 5,000 ms | PC側の時計応答取得待ち |

この三つは別の判定です。今回の製品Heartbeatの0.471 ms成功を、過去の診断失敗履歴で失敗扱いにはしません。反対に、後の製品成功を理由に初回診断失敗を消しません。

初回診断失敗時のepoch・FIFO・ソフトキュー・待ち理由が固定保存されていないため、物理的な発端は未確定です。最後のFIFO記録や、測定後も増える累積timeoutから、過去の停止位置や40秒区間の製品失敗件数を逆算することはできません。

[診断USBの原因切分け](evidence/sync_cause/diagnostic_usb_cause.json)に、確定した分岐と未分離の条件を記録しています。

## 残作業

1. Vehicle専用USBローカル時計要求・返信をtest-firstで追加し、測定ツールの役割対応表を明示する。private要求をPixhawkやE220へ流さない。
2. 診断USBの初回失敗時にframe識別、bootstrap状態、epoch、開始・終了・期限、FIFOとキュー状態を同時に固定保存する。製品106 ms条件は維持する。
3. 新たな実機許可と安全確認後に診断修正を評価する。その後、製品経路で932件30秒・Heartbeat最大2,500 ms・全error 0の同時受入へ進む。

## 公開したソースと証拠

`source_snapshot/` は今回の修正と診断に関係する15ファイルの選別コピーです。直下の旧公開スナップショットを一括更新したものではなく、完全なビルド・書込みパッケージでもありません。

原本との対応・byte数・SHA256は[原本対応一覧](source_inventory.json)に保存しています。元ワークスペースの371件合格、両機コンパイル、17チェック再現は、同梱ログと結果で確認した過去の実行結果です。今回の公開コピー上で全371件を再実行したとは主張しません。

`evidence/live/` の小さなBINは受信raw又は内部診断レコードであり、書込み用applicationではありません。両機の7種類の内部記録、PC取得記録、復旧監査を含めました。candidateのELF・MAP・application BIN、復旧baseline一式、toolchain、EXE、APIキー、使い切った実機許可ファイルは含めません。原本の絶対パスや省略ファイルへの参照は来歴として保持し、新しいPCの実行設定には使用しないでください。

公開時に行ったハッシュ・秘密情報・JSON・リンク検査は[公開検査](validation/summary.json)に記録します。古いrunのmanifestが参照する全ファイルの再検証や、完全なclone再現を保証するものではありません。

本更新の掲載日・本文の日付はJST、run名と原本内のUTC時刻はUTCです。GitHub掲載と過去の許可文言は、将来の実機操作・書込み・再試験の許可にはなりません。
