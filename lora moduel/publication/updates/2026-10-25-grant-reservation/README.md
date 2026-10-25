# R19 Grant予約の実機結果と取得判定の修正

2026年10月25日の進捗です。両USBを使う診断用のGrant予約を追加し、13時35分から13時38分JSTに1回実機評価しました。パラメータは30秒時点・終了時とも0/932件で、高速転送は開始しませんでした。両機はaccepted R18へ復旧済みです。公開操作では実機を操作していません。

## 今回確認できた停止順序

| 境界 | 実測結果 |
|---|---|
| VehicleのGrant予約 | 同一MCU時計で39,202 msに成立、39,356 msにExternalFault detail 13で停止。保持時間154 ms |
| PCが停止通知を受信 | PARAM要求の送信開始より80.4178 ms前、Vehicleへの解放指示より171.4479 ms前。いずれも同一PC時計で比較 |
| Groundの要求受付と停止 | 26,016 msに要求を保持し、26,517 msに停止。501 msでownerとcoordinatorがGrantDeadlineExceeded |
| PARAM要求 | PCの書込みAPIが完全な14 byteを1回受付し、Groundの要求保持も記録。RF・Pixhawk到達の証明ではない。30秒時点・測定終了時とも0/932件 |
| 製品Heartbeat | 合計12件のうち準備中11件、40秒測定中1件。40秒の継続成功ではない |
| Ground初回HeartbeatのUSB完了 | 21 byteを472 µsで完了。106 ms条件以内 |
| AUX | 両機ともfault 0。物理波形の連続正常や故障解消の証明ではない |
| 診断USB | 初回63-byte受付後の31-byte待機が両機に残る |

予約したGrantは生成されていますが、UART受付と物理tail完了は記録されず、TailReady、交渉、bulkへ進んでいません。VehicleはPARAM送信より前に既に停止していました。PC側の解放指示の書込み受付だけで、Vehicle側の解放成立やRF送信成功とは判断できません。[通信停止の派生解析](evidence/cause_analysis/reservation_failure_derived_readonly_analysis.json)

Vehicleのdetail 13は、Heartbeat優先、AUX、writer leaseの不一致、処理中状態などをまとめた停止です。どの条件が最初に成立したかは記録されていません。コード上では、予約保持中に新しいHeartbeatが届くと、2,500 msのHeartbeat期限に対する5,050 msの余裕判定で優先扱いとなり、予約を中止する経路があります。今回を説明できる有力候補ですが、測定済みの単一原因ではありません。

測定ツールはVehicleの停止通知を受信済みでもPARAM要求とReleaseVehicleへ進んでいました。次の通信修正は、予約保持とHeartbeat優先の整合、および要求・解放指示の送信前に既知の停止を検出して中止する判定です。500 msを延ばしたり元の要求時刻を動かしたりして成功扱いにはしません。

## 診断予約と製品運用の区別

今回の予約は、PCが両機のboot、USB epoch、reader session、slot nonce、Grant sessionとcycle、実際のwriter tokenとgenerationを結び付ける診断専用機能です。元の要求受付後に保持したGrantを解放し、実際の送信完了とGroundのguardを別々に検査します。任意の時点から無線だけで高速開始できる製品用予約の完成を意味しません。

両側の500 ms条件、Groundの100 ms guard、製品USBの106 ms、28秒lease、30秒目標、ピン、UART、E220 profileは維持しています。通常製品通信でPowerShellやdual-COM予約を必須にする仕様ではありません。[今回の設計と詳細記録](source_snapshot/R19_GRANT_RESERVATION_DIAGNOSTICS.md)

## 取得判定の不具合とオフライン修正

実機手順の元の結果は`FAIL_STAGE_READ_R18_RESTORED`で、書き換えていません。各readerはv10で各20 rawを取得し、サイズ・SHA256・同一2回読取りが一致しました。しかし親の最終形式許可リストがv9までだったため、取得証明を誤って不成立としました。[親判定の切分け](evidence/cause_analysis/post_repaired_hil_stage_gate_analysis.json)

この許可漏れは、実際の親関数を使う失敗試験を追加してから、v10を許可する1行だけの修正で閉じました。最終条件59項目と、保存済み両機のrawを実関数で再解析する109項目はPS5.1／7で各合格しています。既存の関連52項目・128項目とPS5.1の親手順試験も合格しました。取得判定の修正であって通信改善ではありません。[修正集計](evidence/stage_gate_fix/v10_stage_final_gate_fix_summary.json)

全449/449試験の合格とVehicleからGroundの順の診断ビルドは、今回の実機開始前の結果です。v10判定修正後に全450試験やArduinoビルドを再実行した結果ではありません。使用したv5照合表は親ソース01128370で、修正後はAFC2EBC5です。旧pinは使用済みかつ現行ツールとは不一致であり、次回実行の権限や照合の代わりにはなりません。

同日12時39分の先行手順は、操作記録の未定義変数とUTF8読取りの不具合によりflash書込み前に停止しました。その失敗と修正も選別保存しています。13時35分の再試験では書込み・測定・両機の内部記録取得・R18復旧まで実施できたため、二つの手順を混同しません。

## 保存範囲と再現

関連ソースは[source_snapshot](source_snapshot/)、機器操作を行う三つのスクリプトは実行用配置から外した[source_reference](source_reference/)に、原本と同じbyteで保存しています。候補c198の正本83ファイルと、試験後の判定修正を含むPCツールを区別します。既存の直下ソースや過去の公開記録は置き換えていません。[コピー元とSHA256の台帳](source_inventory.json)

元の実機親summaryと実行許可・操作確認の全文は公開対象から外しています。公開用の[結果抜粋](PUBLICATION_STATUS.json)は派生資料であり、byte一致原本ではありません。原本のSHA256、公開したraw、CRC・時刻の派生解析、[復旧と保存物の独立監査](evidence/cause_analysis/retrial_restore_artifact_independent_audit_20261025T043509262Z.json)で根拠をたどれます。

公開コピーは[公開時検証](validation/summary.json)で、原本一致、JSON、秘密情報パターン、文書リンクを含む5,900項目に合格しました。公開した親関数の参照ソースに対する最終条件59項目もPS5.1／7で各再実行し、合格しています。元ワークスペースの全449試験や実機試験の再実行ではありません。原本の内部リンクや絶対パスには、省略したローカル履歴への参照が残ります。

全build tree、アプリBIN、ELF、MAP、APIキー、実行許可ファイル、使用済みpin、操作確認全文、driver配布物は含めません。小さな`.bin`は通信rawと固定診断記録だけです。原本に残るPCパスとUSB識別子は来歴であり、別環境向け設定や認証情報ではありません。候補・復旧のmetadataは省略したファイルも参照するため、完全な封印済みパッケージでも、そのまま実機へ書き込めるリリースでもありません。

今回の許可は使用済みです。高速通信の受入・Deploymentは未許可のままであり、GitHubへの公開は追加実機操作の許可ではありません。
