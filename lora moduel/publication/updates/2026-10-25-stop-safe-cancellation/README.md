# R19 予約取消し修正と実機評価

2026年10月25日17時台の実機評価では、Heartbeatとの競合による安全取消しの選択とローカル退役条件を確認できましたが、高速転送は開始せず、パラメータ取得は30秒時点・測定終了とも **0/932件** でした。両XIAOは試験終了後にaccepted R18へ復旧し、書込み内容のdigest照合も完了しています。

今回の更新は、前回公開後のファームウェア・測定ツール修正、最終479試験、両機ビルド、実機試験1回をまとめたものです。GitHubへの公開作業では実機操作や再試験を行っていません。

## 修正した内容

- Vehicleの最初の停止判断を128 byteのSTOP128記録に固定し、Heartbeat期限、AUX、writer lease、予約状態などの条件を分けて保存します。既存512 byteの予約履歴は維持します。
- Heartbeat優先と予約が競合したときは、旧GrantのUART受付が0 byteで、旧cycleとwriter leaseの退役を確認できる場合だけ安全取消しを選択します。取消し後はHeartbeatを優先し、両側の取消し応答とpeer確認後に別Grant・別nonceで再予約する設計です。
- PC runnerはPARAM要求・Grant解放指示の直前に両readerの停止通知を確認します。PARAM要求の送信を試みた後は、取消しが届いても再要求・自動再準備を行わず、`ATTEMPTED_ABORT`として終了します。
- 診断USB制御v2とJTAG reader v11を追加しました。各roleで11記録を2回ずつ読み、計22 rawの一致を確認します。従来v1・reader v10は別契約として維持します。

USB製品完了106 ms、GroundとVehicleの各500 ms条件、Heartbeat上限2,500 ms、AUX待ち2,000 ms、Grant hold750 msは変更していません。準備上限はPC15秒・MCU8秒、測定40秒、PARAM要求は最大1回です。

## オフライン検証

元ワークスペースの最終一括試験は479/479合格、失敗0、所要665.53秒でした。初回一括試験の7件失敗と失敗再現ログも保存し、修正後の最終結果と区別しています。Vehicle、Groundの順に診断候補のArduinoビルドが合格しています。

候補のcanonical sourceは85ファイル、測定ツールの固定一覧は27ファイルです。候補の独立監査26項目も合格しています。途中段階の個別summaryにある「全体試験待ち」は、最終合否を示すものではありません。

公開コピーでも純オフラインの予約workflow307項目・取消しworkflow191項目をPowerShell 5.1と7でそれぞれ再確認し、すべて合格しました。これは選別試験の再実行であり、全479試験・Arduinoビルドの再実行ではありません。ログは[公開時検証ディレクトリ](validation/)に保存しています。

- [最終オフラインまとめ](evidence/offline/summary.json)
- [最終479試験ログ](evidence/offline/full-host-final.log)
- [両機ビルドログ](evidence/offline/candidate-arduino-build.log)
- [候補の独立監査](evidence/offline/candidate_independent_audit.json)

## 実機結果

試験時間は2026年10月25日17時32分57秒から17時36分05秒JSTです。診断版書込み、取得要求最大1回を含む40秒測定、両機の内部記録取得、accepted R18復旧を1回実施しました。

| 項目 | 同じrunの結果 |
|---|---|
| PARAM要求 | 1回、14 byteをPC APIが受理。RF・Pixhawk到達の証明ではない |
| 30秒時点・測定終了の取得 | いずれも0/932件 |
| 要求前のPARAM_VALUE | STAT_RUNTIME、index65535を1件観測。取得台帳の932件には算入しない |
| 製品Heartbeat | CRC検証済み10件。準備中9件、40秒測定中1件 |
| Heartbeat継続 | 最後の受信から測定終了まで39,735.2043 ms無受信。2,500 ms条件は不合格 |
| 初回製品HeartbeatのUSB完了 | 同一MCU時計で457 µs。106 ms以内だが、継続通信の成功ではない |
| AUX | 両機のfault codeは0。実波形は未測定 |
| 診断USB | 両機で63 byte受付後、31 byteが送信待ちの失敗記録あり。物理FIFO故障は未証明 |
| 復旧 | 両機ともaccepted R18へ復旧、digest一致。全子処理の終了とJTAG後のCPU runningも確認 |

PARAM台帳の`errors.total=0`はPARAM_VALUEとstream framingの範囲です。予約の停止・診断USB待機が残るため、「全error 0達成」とは扱いません。

## 今回特定できた停止経路

VehicleはMCU時刻36,824 msに`SAFE_CANCEL`、理由`HeartbeatDeadlineConflict`を記録しました。その時点でHeartbeat期限まで2,500 ms、予約判定のreserveは5,050 msでした。AUX HIGH、writer token/generation45は有効で、radio busy・pending action・tailはfalse、旧GrantのUART受付0・旧cycle退役・旧lease退役はtrueでした。

この記録は安全取消しの選択とローカル退役条件を証明しますが、両側の取消し完了、Heartbeatの到達、新予約の成立までは証明しません。今回の完了した取消し回数は0、予約は第1roundのままです。

PCが取消し通知を検出した時点ではPARAM要求は送信済みでした。runnerは`ATTEMPTED_ABORT_WITHDRAWN_AFTER_REQUEST`で中止し、作成済みの`ReleaseVehicle`は送信していません。今回は「PCが既に取得済みの停止通知を要求前に見落とした」とは判断できず、要求後に届いた非同期取消しによる中止です。MCUでの取消し発生とPC書込みの正確な前後関係は、時計を直接比較して断定しません。

Groundは自身の時刻23,551 msに要求を保持し、24,052 msに`GrantWaitExpired`、経過501 msで停止しました。Vehicleは安全取消し後に取消しACK・再予約を完了できず、元の準備上限8秒で`PrepareExpired`となりました。今回のreservation reason13はこの`PrepareExpired`であり、前回の`ExternalFault detail13`とは別の値です。

対象GrantのUART送出・RF tailが成立していないため、「fresh Grant到着」と「Grant tail後の高速開始要求到着」を必要とする正式な両500 ms受入評価は未成立です。今回の結果を高速通信開始成功や低速切替成功には数えません。

## 残課題

要求受付と予約取消しが競合する開始手順を見直し、要求送信後に安全取消しが届く場合の処理を整合させる必要があります。期限を延ばしたり時計をリセットしたりして成功にする方針ではありません。診断USBの31 byte待機も別の課題として残っています。

932/932件・30秒以内・Heartbeat最大2,500 ms以下・全error 0を同一runで確認する製品受入は未完了です。R19のDeploymentは許可していません。実機許可は今回の1回分で消費済みです。

## 保存した証拠と公開範囲

- [公開用結果要約](PUBLICATION_STATUS.json)は、非公開の元summaryから作った派生抽出です。原本と同じJSONであるとは扱いません。
- [40秒取得記録](evidence/trial/capture/summary.json)、[30秒台帳](evidence/trial/capture/param_list_30s.json)、[最終台帳](evidence/trial/param_list_diagnostics.json)、[Vehicle内部記録](evidence/trial/stage_vehicle/summary.json)、[Ground内部記録](evidence/trial/stage_ground/summary.json)を同梱しています。
- [source_snapshot](source_snapshot/)は対象候補の関連ソースと試験の選別コピーです。[source_reference](source_reference/)の3つの実機起動ツールはbyte-identicalな`.reference.txt`データで、実行用入口ではありません。モジュール直下の古いソースは置き換えていません。
- [原本対応とSHA一覧](source_inventory.json)でコピー範囲・除外物を確認できます。[公開時検証](validation/summary.json)はコピー・結果・秘密情報パターン・リンクの検査で、479試験やArduinoビルドの再実行ではありません。

一回限定許可・安全確認の宣言、prepared pin、実機dispatch、APIキー、application image、ELF、巨大なbuild/fixture treeは含めていません。小さなraw診断`.bin`は計50件で、6件の通信rawと44件のJTAG読取りです。candidate/flashのmanifestやsealが参照する省略ファイルもあるため、完全な封印済み配布物・実機書込みパッケージ・全試験のclean-clone再現一式ではありません。元の絶対パスと機器識別子は来歴として残しています。

対象候補は`20261025T075246002Z-0508974a`、実機runは`20261025T083255978Z-stop-v11-param-once`です。元outer summaryのSHA256は`8F15942832D95B586E813EF0BA0A4733E7A747F1ED627ADD338EBC4823B97457`、canonical source treeは`C27939367A5E34481DE6A552F387620A15E97A108BACD2398B9BAC5C7478AA5A`です。
