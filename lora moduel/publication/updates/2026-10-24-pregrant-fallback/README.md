# R19 Grant期限超過と低速切替の実機評価

2026年10月24日の進捗です。要求後に500 msで通信全体が停止する原因をGrant待ち期限超過と確定し、高速交渉前の安全条件を満たす場合だけR18経路へ切り替える修正を実装しました。23時08分から23時11分JSTの1回の実機試験では、期限超過後も通信とパラメータ応答が継続しました。高速転送の成功や932件30秒の達成ではありません。

## 最新の実機結果

| 項目 | 結果 |
|---|---|
| 通信測定 | 40.0018022秒、取得要求1回、PC側API受付14 byte |
| パラメータ取得 | 要求起点30秒で4/932件、測定終了時6/932件。index 0から5 |
| PCで受信した製品Heartbeat | 37件、最大間隔2,099.9267 ms |
| 初回製品HeartbeatのUSB完了 | MCU内で487 µs。106 ms条件以内 |
| AUX安全停止 | 両機とも観測0件。物理波形の連続正常を証明した結果ではない |
| 生通信の再検査 | 6,384 byte、131フレームすべてCRC一致、未解析・途中切れbyte 0 |
| 復旧 | 両機accepted R18へ復旧し、実機内容一致と終了処理を確認 |

[総合評価](evidence/fallback_fix/trial_evaluation.json)、[通信とUSBとAUXの分析](evidence/fallback_fix/usb_aux_product_trial_analysis.json)、[保存証拠の独立監査](evidence/fallback_fix/trial_safety_evidence_audit.json)に対応する原本とSHA256を記録しています。取得台帳のCRC・重複等のエラーは0ですが、診断USBの待機記録は残るため、通信全体の全error 0ではありません。

Heartbeatは検証済みRFフレームを保持するpacerを経てPCへ届きます。PCでの最大間隔は各フレームの新しいRF到着間隔と同じ意味ではありません。今回の6件の有効なPARAM_VALUEと2件のMISSION_CURRENTも、通信継続の判断に使っています。

## 停止原因と修正

比較対象の候補では要求起点から501 msで、Groundのownerとcoordinatorがともに`GrantDeadlineExceeded`を記録しました。期限内に新しいGrantを観測しておらず、高速adapterの失敗が通信全体の停止へ伝わっていました。[修正前の原因記録](evidence/previous_grant_failure/grant_cause_analysis.json)

今回も500 ms条件は維持しています。Groundの要求起点12,770 msに対し、期限超過は13,271 msです。その後もbridge-readyの状態記録、通常UART動作、製品Heartbeatとパラメータ応答が続きました。封印済みソースの経路と合わせて、安全な低速切替が使われたことを強く裏付けています。切替回数の新しいRAM値を直接読んだ結果ではありません。[Grantと切替の分析](evidence/fallback_fix/grant_fallback_trial_analysis.json)

修正は、高速交渉が未開始で、新旧Grant・USB epoch・writer・保持要求・通常キューに不整合がない場合に限定します。同じ元の要求を通常のproxy経路へ1回だけ渡し、失敗した高速adapterを再起動しません。交渉済み、送信prefixが不明、USB状態変化などの不確実な条件では安全停止を維持します。通常キューが空であることも条件なので、あらゆる混雑状態での切替成功を証明する修正ではありません。

500 ms、AUX 2,000 ms、製品USB 106 ms、元の要求時刻、28秒lease、30秒目標、UART・RF・ピン設定は変更していません。

## 修正前の失敗試験と検証

最初に安全切替がない状態の失敗試験を保存し、さらにキュー受付中のUSB epoch変化を見逃す条件を失敗試験で再現しました。修正後の関連19試験と、元ワークスペースの全体430/430試験が合格しています。続くVehicleからGroundの順の診断ビルド、候補の封印と照合も合格しています。[修正集計](evidence/fallback_fix/summary.json)と[オフライン証跡監査](evidence/fallback_fix/offline_validation_audit.json)

候補は`20261024T134821302Z-9e36e182`、canonical bridgeのSHA256は`896D1014C6BB75686F5A4EA0D5F5DA4A98E7DE83541E0288E3D6ED6226E9168E`です。実機試験は一回限定で実施し、追加試験・自動再試行は行っていません。保存証拠の独立監査1,022項目と生通信の整合確認17項目も合格しています。

## 残る問題と高速通信の次段階

932件30秒の目標は未達です。高速交渉の開始条件は未解決であり、今回の対策は低速経路での通信継続です。診断USBはVehicleで31 byte、Groundで59 byteのsoftware ring待機を記録しました。これはRFの欠落byte数ではありません。Groundの失敗がPCのcloseより後かという因果は、保証付き時計対応がないため未確定です。AUXも安全停止はなかったものの、Groundの最大観測間隔100.591 msと割込み履歴overflow 84があり、物理波形の連続正常は未証明です。

次の内容は未実装の修正案です。現行ツールはARMと最初のHeartbeatの後に要求を送るだけで、次のGrantまで500 ms以内となる位相を保証しません。Grantの直後に要求を送っても、そのGrantは基準となり、さらに新しいGrantが必要です。[開始条件の整合検証](evidence/grant_alignment/contract_review.json)

高速開始制御と測定手順を整合させ、Groundの要求受付から新Grant受信まで500 ms以内、Vehicleの同一Grant送出完了から高速開始要求受信まで500 ms以内を別々に確認する必要があります。要求を待たせた時間を隠したり、時刻をリセットしたりせず、実際の高速交渉・転送・終端まで追跡します。その同一runで932/932件・30秒以内・Heartbeat最大2,500 ms以下・全error 0を評価します。条件をそろえた試験と、任意タイミングでも高速開始できる製品設計は分けて扱います。

## 公開範囲と再現

関連コードは[source_snapshot](source_snapshot/)へ原本のまま選別コピーし、既存の直下製品ソースや過去の更新は置き換えていません。[source_inventory.json](source_inventory.json)にコピー元・保存先・byte数・SHA256を記録しています。[公開時検証](validation/summary.json)では、原本一致・秘密情報パターン・文書リンク・選別ソースのオフライン試験を区別します。公開コピーでも関連18試験を再実行し、18/18件が合格しました。初回のヘッダー不足によるビルド失敗と、原本ヘッダー追加後の再検証ログも保持しています。元ワークスペースの全430件やArduinoビルドを公開操作で再実行したという意味ではありません。

候補・復旧のmetadataやsealは省略したBIN・ELF・MAP・過去runも参照します。今回保存したのは証拠の選別アーカイブであり、完全な封印済みパッケージでも、実機へ書込み可能なリリースでもありません。実行許可ファイル、操作確認全文、PnP一覧、アプリ実行BIN、build tree、認証キーは含めません。小さな`.bin`は通信生データと固定診断記録だけです。原本にはPCパスやUSB個体識別子が含まれますが、別環境用の設定値ではありません。

現在の実機は両方accepted R18です。高速通信の受入・Deploymentは未許可であり、GitHub公開や過去の許可記録は追加実機試験の許可にはなりません。
