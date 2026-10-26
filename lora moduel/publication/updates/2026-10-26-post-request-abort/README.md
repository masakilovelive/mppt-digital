# R19 予約取消し後の中止処理と開始タイミング

2026年10月26日JSTの進捗です。予約取消し後にGroundがGrant待ちへ残る経路と、Vehicleの通常通信中に中止処理が拒否される経路を、失敗試験を追加して修正しました。元ワークスペースで全548試験、VehicleからGroundの順の診断ビルド、新候補の独立照合に合格しています。修正後の実機試験はまだ行っておらず、932件を30秒以内に取得する目標は未達です。[修正と検証の集計](evidence/offline/summary.json)

## 直前の実機試験で確認した停止順序

2026年10月26日01時16分から01時19分JSTの試験は、修正前の候補を使用しています。両機のCommitAckを確認してPARAM要求を1回送信しましたが、その後に予約取消しを検出し、Grant解放指示は送っていません。30秒時点・終了時とも0/932件でした。[実機結果の解析](evidence/preceding_live/assessment/root-result-summary-001.json)

- VehicleはPreparedから450 ms後、Heartbeat期限との競合で、未送信のGrantを安全取消ししました。旧cycleとwriter leaseの退役は記録されています。その後のAbortRequestでは中止処理が拒否され、detail 20が残りました。以前のdetail 13とは別の停止です。
- Groundは要求受付から501 msでGrant待ち期限超過になりました。新しいGrant受信と高速転送開始は成立していません。
- 初回の製品HeartbeatはUSB送信完了474 µsでしたが、測定中は1件のみで末尾約39.6秒が無受信です。初回成功をHeartbeat継続成功とは扱いません。
- AUX faultは両機0でした。診断USBの63 byte受付後に31 byteが待機する問題は両機に残りました。AUXの実波形は測定していません。

MCUの経過時間は同じ機体の時計内、PCの経過時間は同じPC時計内で比較しています。異なる時計を直接差し引いて、物理的な先後関係を確定していません。両機の内部記録と小さなraw記録は[Vehicle](evidence/preceding_live/stage_vehicle/)・[Ground](evidence/preceding_live/stage_ground/)、取得台帳は[30秒時点](evidence/preceding_live/capture/param_list_30s.json)に保存しています。試験終了時には両機のaccepted R18への書込み・照合・再認識を確認済みですが、復旧後のMAVLink受入試験は別途です。

## 今回の修正

1. 完全受信した取消し通知が失敗状態への遷移時にも受信バッファから退役するようにしました。次のbyteが来ないために中止処理へ進めない経路を閉じています。
2. 通常のPARAM・Heartbeat解析より先に、両機へのAbortを優先します。一方のAbortAckを待って他方への指示を遅らせず、各機への送信は最大1回、PARAM要求は最大1回のままです。指示直前にも相手の識別・現在の予約tuple・読取り継続・送信上限を検査します。
3. 未送信で安全に退役済みの旧Grantだけを無効化できるようにしました。別の正しいStandardTdd送信が進行中でも、そのwriterを取消し・解放・再送せずに旧予約を閉じます。不明なbusy、古いlease、高速所有者、USB epoch不一致などは引き続き拒否します。
4. Groundの期限超過後に届いたAbortは、厳密に一致する未交渉の旧要求だけを隔離します。最初の失敗、元の要求時刻、失敗したadapterは保持し、期限超過を成功へ読み替えません。
5. Prepared公開の直前にもHeartbeatの緊急性を確認します。競合する未公開Grantは実際のTDD cycleを退役させ、通常Heartbeatを優先して別の新しいcycleを待ちます。元の準備期限をリセットせず、公開済み予約の取消し回数にも読み替えません。

製品USB 106 ms、Groundの要求受付からfresh Grantまで500 ms、VehicleのGrant tailから開始まで500 ms、Heartbeat 2,500 ms、AUX 2,000 ms、hold 750 ms、MCU準備8秒・PC準備15秒は維持しています。ピン・UART・E220 profile・無線パラメータ・診断記録ABIも変更していません。[bridgeの差分](evidence/offline/bridge-abort/final-bridge.diff)・[coreの差分](evidence/offline/core-abort/diff.json)・[runnerの差分](evidence/offline/runner-abort/diff.json)

## 検証結果

| 検証 | 元ワークスペースの結果 |
|---|---|
| 最終一括ホスト試験 | 548/548合格、失敗0、611.82秒 |
| 実bridgeの予約処理試験 | 42件合格、新規6件を登録 |
| coreの予約確定と中止処理 | 1,463チェック合格 |
| runner関連の重点試験 | PS5.1・PS7で各822チェック合格 |
| PARAM試験fixtureの修正 | PS5.1・PS7で各72チェック合格 |
| Arduino診断ビルド | Vehicle → Groundの順に両機合格 |
| 生成した候補の独立照合 | 合格 |
| 新候補に結び付けた読取り契約試験 | PS5.1・PS7で各109チェック合格。実JTAG操作ではない |

[最終548試験ログ](evidence/offline/full-host-verified.log)、[ビルドログ](evidence/offline/arduino-diagnostic-build.log)、[独立照合ログ](evidence/offline/candidate-independent-verification.log)を保存しています。最終606入力のhashは試験後・ビルド後とも変更0でした。途中の2回の一括試験は中断であり、合格として集計していません。元の失敗・中断ログと、最終548件の合格ログを分離して残しています。

新候補は`20261026T023007458Z-ccd7d4c8`です。[候補metadata](evidence/candidate_metadata/)にはmanifest・seal・compile記録だけを保存し、アプリBIN・ELF・MAP・完全なpackageは含めません。これは書込み可能な封印済みリリースではありません。

## 公開範囲

[source_inventory.json](source_inventory.json)で原本のパス・コピー先・SHA256を確認できます。606検証入力のうち生成物22件を除外し、584入力と変更済みHWCDC関連4ファイルをbyte一致で保存しました。中止・書込みを行う主要3スクリプトは、以前と同じく実行用配置から外した[source_reference](source_reference/)へ保存しています。関連ソース全体は[source_snapshot](source_snapshot/)です。

製品スケッチ内の標準コピーと、`firmware/phase6/`のcanonical bridgeは役割が異なります。新R19候補はcanonicalソースを専用packageへ組み立てて生成したもので、製品スケッチ内のコピーをそのまま新候補とみなしてはいけません。

巨大な合成fixture、全build tree、秘密情報、実行許可ファイル、操作確認全文は公開していません。過去の実機親summary・capture親summaryは省略し、解析記録・両機の記録・台帳を選別しました。原本内の絶対パスや省略ファイルへの参照は来歴として残ります。選別コピー全体を使った548件のclean-clone再実行やArduino再ビルドを、この公開作業で実施したという意味ではありません。[公開物の整合性検査](validation/summary.json)

## 残る確認

実機での両AbortAck、古いReleaseの不成立、Heartbeat継続、実際の高速取得は未確認です。PreparedやCommit後に新しい緊急Heartbeatが来れば、安全取消しが必要になる場合があります。今回の変更は将来の750 msの空き時間を保証するものではありません。中止応答用キューが満杯になる防御分岐も、意図的な実行再現までは行っていません。

診断USBの31 byte待機は別の未解決課題です。次回は新候補に対応する手順・照合情報を準備し、新しい一回限定許可と安全確認後に実機評価します。最終条件は932/932件・30秒以内・Heartbeat最大2,500 ms以下・全error 0の同一run達成です。受入・Deploymentは未許可のままです。
