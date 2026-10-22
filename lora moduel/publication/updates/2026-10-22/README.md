# R19保存修正とAUX判定の切分け

2026年10月22日JSTの更新です。測定ツールの保存不具合は修正後の実機試験で再現せず、40秒測定、両機の内部記録取得、accepted R18への復旧まで完了しました。一方、GroundのAUX待ち停止とREADY未受信が残り、R19の製品通信受入は未完了です。

## 実機で確認した結果

| 項目 | 結果 |
|---|---|
| 測定時間 | PC単調時計で40.0119898秒 |
| Vehicle USB受信 | 2,646 byte、CRC正常の診断42フレーム |
| Ground USB受信 | 154 byte、CRC正常の診断2フレームと時刻応答1フレーム |
| CRC異常、部分フレーム、ノイズ | 両機とも0。ただしUSB診断データの結果であり、無線やUARTの無誤り証明ではない |
| PC連続読取りの最大サービス間隔 | Vehicle 43.1340 ms、Ground 43.1292 ms |
| 保存処理 | 両機の生データ、取得メタデータ、終了記録を保存。保存エラー0 |
| JTAG内部記録 | 各機6種類を2回取得し、全ペア一致 |
| 試験後 | 両機をaccepted R18へdigest照合付きで復旧 |

実機結果の正本は[試験結果と原因切分け記録](evidence/live/operator_evaluation.json)です。
[PC取得記録](evidence/live/capture/summary.json)、[Ground内部記録](evidence/live/stage_ground/summary.json)、[Vehicle内部記録](evidence/live/stage_vehicle/summary.json)を同梱しています。

Groundは同じnonceの時刻応答をPCまで返しましたが、試験開始準備を通知するREADYは未受信でした。PCはARMを送信しておらず、機器のARM受理も記録されていません。製品Heartbeatの106 ms条件、932件30秒取得、Heartbeat最大2,500 msは今回未評価です。外側手順のPASSは「証拠取得とR18復旧の完遂」であり、通信受入のPASSではありません。

## AUX停止で確認できた境界

Groundの初回停止通知は `AuxDidNotReturnHigh` です。MCUのE220書込み制御がLOWを観測した後、所定のHIGH安定条件を確認できないまま、2,000 ms以上経過した呼出しで安全停止しています。UART APIが要求分を受け付けた後の判定であり、部分書込みを示すエラーとは異なります。

実機の診断状態は、起動後11,037 msの `AwaitingAuxHigh / fault 0` から、11,261 msの `FailClosed / fault 5` へ変わっています。前者は保持中の状態を写した記録で、11,037 msにGPIOを新規採取した証拠ではありません。

この停止だけでは、物理AUXが連続してLOWだったのか、HIGH復帰後のMCU観測が遅れたのかは判断できません。E220本体の故障、配線不良、電源不足又はRF破損が確定したわけではありません。AUX停止がREADY未受信を直接引き起こしたかも未確定です。

## 同じ異常になる二つの入力

sealed candidateと同じC++コアを用いた合成入力の比較は、10ケース153チェックで合格しました。

| 合成入力 | 製品コアの結果 |
|---|---|
| UART受理時にLOWを観測し、LOWのまま期限まで観測 | fault 5 |
| 一度LOWを観測した後、物理HIGH復帰を仮定するが、MCUの次の観測が2秒後 | 同じfault 5 |
| 同じ短いLOWの後、MCUがHIGH復帰を適時に観測 | 正常完了 |

LOW後の初回HIGH観測では、その観測時刻が15 ms安定確認の起点になります。観測が遅ければ、実際の信号が既にHIGHでも安定確認が足りず、同じ停止になる経路があります。USB診断処理が通常のAUX観測より先にreturnするソフト経路もありますが、今回その経路で実際に観測が遅れたことまでは記録されていません。

[切分け結果](evidence/aux_discrimination/summary.json)、[比較試験ソース](evidence/aux_discrimination/aux_observation_probe_final.cpp)、[153チェックの結果](evidence/aux_discrimination/final_probe_result.json)を参照してください。合成の物理波形は仮定であり、過去のE220波形を測定した結果ではありません。

## 保存処理の修正

直前試験は、測定ツールの型付き変数名の衝突により、Vehicleの生データ保存後にGroundと取得メタデータの保存が停止しました。[直前試験の記録](evidence/prior_capture_failure/operator_evaluation.json)は変更せず保持しています。

修正後は両機の取得済み生データを先に保存し、付加情報の整形失敗でも失敗記録を残します。既存記録を上書きせず、欠測を0 byteの正常測定へ置き換えません。Windows PowerShell 5.1とPowerShell 7で各295チェック、元ワークスペースの全体試験360件、Vehicle→Groundの通常版コンパイルが合格しています。[保存修正の正本](evidence/persistence_fix/summary.json)と[差分](evidence/persistence_fix/changes.diff)を同梱しています。

これらは元ワークスペースでの検証結果です。GitHub公開コピーで今回再実行した項目とは、[公開時検証記録](validation/summary.json)で区別しています。

## 公開コピーでのオフライン確認

`source_snapshot/` は今回の測定ツール17ファイル、限定オフライン試験、AUX比較に必要なコア等の選別コピーです。すべて[原本対応一覧](source_inventory.json)のSHA256で原本と照合しています。`lora moduel`直下の既存ソースを一括更新したものではなく、この選別コピーから全360件の再現を保証しません。

このディレクトリをカレントにした場合、保存処理の限定試験は次のように実行できます。機器は接続不要です。出力は選別コピーの `runs/validation/` 以下へ生成されます。

```powershell
$snapshot = (Resolve-Path './source_snapshot').Path
& "$snapshot/tests/hil/check_r19_timed_path_capture_entrypoint.ps1" -RepoRoot $snapshot
& "$snapshot/tests/hil/check_r19_timed_path_capture_persistence.ps1" -RepoRoot $snapshot
```

AUX比較はC++17対応コンパイラで、次の2ソースを `source_snapshot/core/include` をinclude先にしてコンパイルします。

- `evidence/aux_discrimination/aux_observation_probe_final.cpp`
- `source_snapshot/core/src/runtime_contract.cpp`

## 次の切分けに必要な記録

原因確定には、初回fault時のGPIO値、LOW状態開始時刻、HIGH追跡開始時刻、直前と今回の観測時刻、最大観測間隔、UART受付時刻とbyte数を保持する必要があります。AUXの独立したエッジ記録と、USB診断の待機・return区間を同じMCU時計で比較します。エッジの欠測や割込み遅延を除外できなければ、物理LOW継続の確定には外部波形測定が必要です。

今回の切分け作業では新しい診断ファームを実装・書込みしていません。106 ms、2,000 ms、15 ms、550 ms、UART、TDD、E220設定は維持しています。追加の実機試験には新しい1回限定許可と安全条件確認が必要です。

## 同梱範囲

選別した原本172ファイルをbyte単位で保持しています。小さな `.bin` はUSB受信又は内部診断記録であり、今回の追加物にはapplication BIN、EXE、DLL、ELF、MAP、APIキーを含めません。書込み・復旧の記録にあるmanifestは、省略したファイルも参照します。ここにある記録や過去の許可文言を、そのまま実機操作の許可として再利用しないでください。

run名と原本の記録時刻はUTC、本文の実施日はJSTです。絶対パスと機器識別子は原本の来歴として保持し、移植先の設定には使用しません。
