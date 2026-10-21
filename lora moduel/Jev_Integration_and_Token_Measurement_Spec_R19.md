# Jev導入・Codexトークン測定仕様（VC LoRa Bridge R19）

- 文書版: 0.1
- 作成日: 2026-09-22
- 対象: VC LoRa Bridge R18低速製品版／R19高速転送候補
- 参照正本: `CURRENT_WORKSPACE_AND_SPEC_R19.md`、`README.md`

## 1. 目的

JevをPC側の診断ゲートとして導入し、既存の通信仕様、安全規則、受入基準を変更せずに、Codexへ渡す試験回数とコンテキスト量を削減する。

あわせて、Jev導入前後のCodex使用量、費用、修正品質を同じ条件で記録し、削減効果を定量評価する。

## 2. 基本方針

Jevはファームウェア、TDD制御、MAVLink転送経路へ組み込まない。PC側で保存済み試験結果を評価する助言機能として使用する。

```text
ホスト試験／HIL試験
        ↓
summary.json・テスト結果
        ↓
固定ルールによる判定
        ↓
曖昧な場合だけJev
        ↓
定義済みの次処置を選択
        ↓
必要な場合だけCodex
        ↓
再試験・固定基準による最終判定
```

### 2.1 役割分担

| 担当 | 役割 |
|---|---|
| ローカルスクリプト | ログ集計、明確な合否判定、受入条件の強制 |
| Jev | 原因分類、追加試験・次処置の選択、Codex移行要否の判定 |
| Codex | 未知原因の解析、コード修正、設計変更 |
| ホスト試験／HIL | 修正結果の検証 |
| 人間 | 実機書込み、通信設定変更、最終承認 |

### 2.2 Jevへ許可しない操作

- Vehicle／Groundへの自動書込み
- COMポートの自動操作
- E220永続設定の変更
- UART、air rate、sub-packet、TDD定数の変更
- `live_flash_authorized`の変更
- 受入基準の緩和
- 固定ルールによるFAILのPASS化

API接続に失敗した場合はローカル固定判定へ戻り、試験そのものを停止させない。

## 3. R19固定受入条件

JevとCodexの判断にかかわらず、以下を固定する。

| 項目 | 合格条件 |
|---|---:|
| `PARAM_VALUE` | exact `932/932` |
| R19完了時間 | `t1 - t0 <= 30,000 ms` |
| Heartbeat | first／max／post gapすべて `<= 2,500 ms` |
| 欠落・重複・順序異常 | すべて0 |
| CRC・parser・partial・control leakage | すべて0 |
| rejected／zero write | 同一bytesを保持し、ordinal・件数を進めない |
| R19実機書込み | `live_flash_authorized=true`の明示承認後のみ |

## 4. Jev入力・出力仕様

### 4.1 入力

生ログ、ソースコード全体、仕様書全文を送らず、既存の`summary.json`から必要な測定値だけを抽出する。

```json
{
  "schema_version": "r19-jev-input-1",
  "run_id": "R19-HOST-001",
  "source_hash": "<sha256>",
  "test_scope": "host",
  "host_tests_passed": 250,
  "host_tests_failed": 1,
  "sanitizer_errors": 0,
  "expected_params": 932,
  "received_params": 520,
  "first_missing_index": 520,
  "heartbeat_max_ms": 2219.603,
  "crc_errors": 0,
  "parser_errors": 0,
  "physical_tail_proven": false,
  "live_flash_authorized": false
}
```

### 4.2 出力

Jevには自由文の修正案を生成させず、次のような許可済み処置IDから1つを選択させる。

```text
RUN_FOCUSED_GRANT_TEST
RUN_DIRECTION_GUARD_TEST
INSPECT_FINAL_VCB1_TAIL
INSPECT_VCTA_PHYSICAL_DRAIN
COLLECT_MORE_EVIDENCE
CODE_REVIEW_REQUIRED
HUMAN_REVIEW_REQUIRED
STOP_SAFETY_CONDITION
```

処置の整合性を保つため、最初は「原因」と「処置」を独立質問にせず、原因と処置を組み合わせた選択肢として評価する。

### 4.3 確信度による処理

| Jev確信度 | 処理 |
|---:|---|
| `>= 0.90` | 読取り専用解析、focused host testなど安全な処理だけ自動実行可能 |
| `0.70–0.90未満` | 推奨表示。Codexまたは人間の確認後に実行 |
| `< 0.70` | 追加証拠を取得し、修正しない |
| API失敗 | ローカル固定判定へフォールバック |
| 安全条件抵触 | 確信度に関係なく停止 |

閾値はシャドー評価結果に基づいて再校正する。閾値変更はバージョン管理し、過去結果へ遡及適用しない。

## 5. Codexコンテキスト生成仕様

Jevが`CODE_REVIEW_REQUIRED`を選んだ場合だけ、Codex用の診断パッケージを生成する。

```text
Codexへ渡す情報
├─ run_id、source hash、試験モード
├─ Jevの処置IDと確信度
├─ 失敗したテスト名
├─ 関係する測定値
├─ エラー前後の限定ログ
├─ allowlistに登録された関係ファイル
├─ 直前の変更差分
└─ 変更禁止条件・固定受入条件
```

Codexへプロジェクト全体を毎回投入しない。関係ファイルの選択規則は`action_id`ごとのallowlistとして固定する。

## 6. トークン量測定仕様

### 6.1 測定目的

次の3点を判定する。

1. Jev導入によってCodexの入力・出力トークンが減ったか。
2. トークン単価を反映したCodexクレジット消費が減ったか。
3. 修正品質、再試行回数、解決時間を悪化させずに節約できたか。

### 6.2 測定単位

- 最小単位: 1回の試験実行から最終処置決定までを1 `run`とする。
- 修正単位: 同一障害に対する複数runを1 `issue_id`へ束ねる。
- 評価単位: 受入試験を通過した1件の`accepted_fix`とする。

同じ障害の再試行を別の成功件数として数えない。

### 6.3 収集項目

各runについて以下をJSON LinesまたはCSVへ保存する。

| 分類 | フィールド | 内容 |
|---|---|---|
| 識別 | `run_id` | 試験実行ID |
| 識別 | `issue_id` | 同一障害を束ねるID |
| 条件 | `mode` | `baseline_codex`または`jev_hybrid` |
| 条件 | `source_hash` | 入力ソースのSHA-256 |
| 条件 | `codex_model` | 使用モデル |
| 条件 | `reasoning_effort` | 推論強度 |
| Codex | `input_tokens` | 非キャッシュ入力 |
| Codex | `cached_input_tokens` | キャッシュ入力 |
| Codex | `output_tokens` | 出力トークン |
| Codex | `total_tokens` | 上記トークン合計 |
| Codex | `codex_called` | Codexへ移行したか |
| Jev | `jev_input_tokens` | Jev入力トークン |
| Jev | `action_id` | 選択処置ID |
| Jev | `confidence` | 確信度 |
| 品質 | `route_correct` | 人間レビューで処置が妥当か |
| 品質 | `accepted_fix` | 固定受入条件を通過したか |
| 品質 | `retry_count` | 同一issueの再試行回数 |
| 品質 | `safety_violation` | 禁止操作・基準緩和の有無 |
| 時間 | `elapsed_seconds` | 開始から処置確定まで |
| 費用 | `codex_credits` | モデル別レートによる換算値 |
| 費用 | `jev_cost_usd` | Jev従量料金 |
| 根拠 | `usage_source` | `api_exact`、`dashboard_batch`、`estimated` |

### 6.4 記録例

```json
{
  "measurement_schema": "jev-token-eval-1",
  "run_id": "R19-HOST-001",
  "issue_id": "R19-GRANT-HANDOFF-001",
  "mode": "jev_hybrid",
  "source_hash": "<sha256>",
  "codex_model": "gpt-5.6-sol",
  "reasoning_effort": "medium",
  "codex_called": true,
  "input_tokens": 12000,
  "cached_input_tokens": 4000,
  "output_tokens": 6000,
  "total_tokens": 22000,
  "jev_input_tokens": 950,
  "action_id": "CODE_REVIEW_REQUIRED",
  "confidence": 0.91,
  "route_correct": true,
  "accepted_fix": true,
  "retry_count": 1,
  "safety_violation": false,
  "elapsed_seconds": 1080,
  "codex_credits": 4.24,
  "jev_cost_usd": 0.0000399,
  "usage_source": "api_exact"
}
```

`codex_credits`の値は説明用の例であり、実運用では測定時点の公式レート表と実際のモデルを使用して再計算する。

### 6.5 データ取得の優先順位

1. API応答に含まれる実測usage値
2. Codex使用量ダッシュボードのバッチ前後差分
3. 対象モデルの入力トークン計数機能による事前計数
4. tokenizerによる推定
5. 文字数からの概算

`api_exact`と`estimated`を同じ精度として集計しない。正式な削減率は原則として`api_exact`だけ、または同一方式で測定した比較ペアだけから算出する。

ChatGPTプラン経由でタスク単位の正確な内訳が取得できない場合は、同じ作業分類を複数件まとめ、使用量ダッシュボードの前後差分をバッチ単位で比較する。

### 6.6 トークン削減率

```text
Codex総トークン = input_tokens
                + cached_input_tokens
                + output_tokens

トークン削減率 = 1 - (Jev導入後Codex総トークン
                     / 導入前Codex総トークン)
```

入力、キャッシュ入力、出力の削減率も別々に算出する。

### 6.7 クレジット換算

モデル別レートを次の変数として持ち、コードへ固定値を直接埋め込まない。

```text
R_input  = 100万入力トークン当たりのクレジット
R_cached = 100万キャッシュ入力トークン当たりのクレジット
R_output = 100万出力トークン当たりのクレジット

Codexクレジット =
  (input_tokens        × R_input
 + cached_input_tokens × R_cached
 + output_tokens       × R_output) / 1,000,000
```

OpenAIのレート変更に備え、各レコードに`rate_card_version`と`measured_at`を保存する。

### 6.8 純費用削減

```text
純削減額 = 導入前Codex費用
          - 導入後Codex費用
          - Jev費用
          - 追加インフラ費用
```

Jevが無料プロモーション中でも`jev_cost_usd=0`と記録し、恒久的な無料サービスとは仮定しない。

### 6.9 成功調整後の効率

主KPIは次とする。

```text
合格修正1件当たりクレジット =
  (Codexクレジット + Jev換算費用) / accepted_fix件数
```

補助KPI:

- 1 issue当たりCodex呼出回数
- Codex移行率
- Codex入力コンテキスト削減率
- Jev正ルーティング率
- 平均再試行回数
- issue解決時間の中央値と90パーセンタイル

## 7. A/B評価計画

### 7.1 比較群

| 群 | 処理 |
|---|---|
| Baseline A | 全対象を従来どおりCodexへ渡す |
| Hybrid B | 固定ルール→Jev→必要時のみCodex |

可能な場合は、同じ保存済み試験結果を独立セッションへ投入するpaired replayを行う。

### 7.2 固定条件

- Codexモデル
- 推論強度
- ソースhash
- 入力試験結果
- 出力要求形式
- ツール許可範囲
- 受入試験
- タイムアウト
- 最大再試行回数

モデル変更、プロンプト変更、Jev導入を同時に比較しない。

### 7.3 サンプル構成

次の障害区分を偏りなく含める。

1. 正常PASS
2. 既知の試験失敗
3. 設定・証拠不足
4. 曖昧な通信障害
5. 新規コード欠陥
6. 安全停止が必要な事例

- パイロット評価: 合計30 issue以上
- 正式評価: 合計100 issue以上
- 各障害区分: 原則10件以上

### 7.4 統計集計

平均値だけでなく、中央値、90パーセンタイル、最大値を報告する。少数の巨大コンテキストが平均値を歪めるため、issue別分布と障害区分別結果も残す。

## 8. 暫定採用基準

以下は導入初期の暫定値であり、シャドー評価後に確定する。

| 指標 | パイロット基準 | 成熟後目標 |
|---|---:|---:|
| Codex総トークン削減率 | `>= 60%` | `>= 80%` |
| Codexクレジット削減率 | `>= 50%` | `>= 75%` |
| Jev正ルーティング率 | `>= 90%` | `>= 95%` |
| accepted fix率 | Baselineを下回らない | Baseline以上 |
| 平均再試行回数 | Baselineを上回らない | Baseline以下 |
| 解決時間中央値 | Baselineを上回らない | 20%以上短縮 |
| 重大障害見逃し | 0件 | 0件 |
| 安全規則違反 | 0件 | 0件 |
| 未承認実機書込み | 0件 | 0件 |

削減率を達成しても品質ガードレールを1件でも破った場合は自動化範囲を拡大しない。

## 9. 保存構成

```text
tools/
└─ jev_advisor/
   ├─ src/
   │  ├─ collect_run.ts
   │  ├─ evaluate_run.ts
   │  ├─ policy_gate.ts
   │  ├─ build_codex_context.ts
   │  └─ record_usage.ts
   ├─ schemas/
   │  ├─ r19_decision_input.schema.json
   │  └─ token_measurement.schema.json
   └─ policies/
      └─ r19_actions.json

runs/decision/<run_id>/
├─ input.json
├─ deterministic_result.json
├─ jev_result.json
├─ final_action.json
├─ context_manifest.json
└─ token_usage.json

runs/decision/_aggregate/
├─ token_usage.jsonl
├─ baseline_summary.json
├─ hybrid_summary.json
└─ evaluation_report.md
```

## 10. 段階的導入

### Phase A: シャドー評価

- 過去ログでJevを実行する。
- 処置は実行しない。
- 人間の判断と比較する。
- トークン削減量はシミュレーションとして計算する。

### Phase B: 診断支援

- 最新試験後にJevを1回呼ぶ。
- 処置候補と確信度を表示する。
- 実行は人間が承認する。
- Baselineとの実測比較を開始する。

### Phase C: ホスト試験の半自動化

- 読取り専用解析
- focused host test
- ASan／UBSan
- 全ホストsuite

上記だけを許可する。失敗時は停止し、Codexまたは人間へ移行する。

### Phase D: Codex連携

- `CODE_REVIEW_REQUIRED`の場合だけCodexを呼ぶ。
- Codexの変更後はRED→GREEN、focused test、全suite、Arduino clean compileを実施する。
- 不合格なら採用せず、同一issueとして再試行を記録する。

### 実機操作

実機書込み、E220設定変更、Mission Planner HILは引き続き人間の承認を必須とする。

## 11. 判定

Jevは合否判定の正本ではなく、Codexを呼ぶ必要性と次に取得すべき証拠を選ぶ診断ゲートである。

導入の成功は、単純なトークン削減ではなく、固定受入基準を維持した「合格修正1件当たりクレジット」の改善で判定する。

## 12. 参考情報

- OpenAI Codex料金・使用量: https://learn.chatgpt.com/docs/pricing
- TypeSafe AI Jev: https://typesafe.ai/blog/introducing-system-one-models-and-jev
- Vercel AI Gateway Jev: https://vercel.com/ai-gateway/models/jev
