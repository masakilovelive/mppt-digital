# VC LoRa Bridge — 検証実験アーカイブ

2026-10-21時点のLoRa通信検証・R19診断開発を、指定フォルダ `lora moduel` にまとめた公開スナップショットです。
今回は資料・ソース・選別した証拠の公開のみで、ファームウェアの変更、実機操作、通信条件変更は行っていません。

## 現在の結論

- R18低速経路には、Mission Plannerで932/932パラメータを取得した過去の受入実績があります。取得時間6,045.839秒、同区間のHeartbeat最大間隔2,206.203 msです。
- R19の目標は「932件を30秒以内、Heartbeat最大2,500 ms以下、全error 0」の同時達成ですが、**未達・受入未完了・Deployment未許可**です。
- 直近のR19診断では、Groundの初回Heartbeat 21 byteをUSBライブラリが受理した後、プロジェクト固有の106 ms完了条件を満たさず停止した証拠があります。これはRF故障やPC読取り不良の確定ではありません。
- その後の別の受信専用確認では、COM6を60.011493秒開いて受信0 byte／送信0 byteでした。この時の搭載ファームウェアhashは未照合で、過去R19と同一原因とは判定できません。
- 最新のUSB-JTAG接続確認は両機PASSですが、CPU・USB FIFO・無線・MAVLink通信の正常性を証明したものではありません。

詳しい現状・時系列は[作業場所と仕様の統合資料](CURRENT_WORKSPACE_AND_SPEC_R19.md)の§31.55〜31.60、図解は[通信シーケンス図](docs/SEQUENCE_DIAGRAMS.md)を参照してください。
後日更新された本資料と古いレポートで内容が異なる場合は、対象run・ソースhash・観測時刻を確認し、異なる試験を混同しないでください。

## 読む順番

| ファイル／ディレクトリ | 内容 |
|---|---|
| [CURRENT_WORKSPACE_AND_SPEC_R19.md](CURRENT_WORKSPACE_AND_SPEC_R19.md) | 作業場所、固定仕様、受入実績、未解決事項、履歴 |
| [docs/SEQUENCE_DIAGRAMS.md](docs/SEQUENCE_DIAGRAMS.md) | 現在の0 byte、過去R19のUSB完了失敗、JTAGの判定範囲 |
| [SPEC.md](SPEC.md) / [PROTOCOL.md](PROTOCOL.md) | 製品仕様・通信プロトコル |
| [PROJECT_README.md](PROJECT_README.md) | 元ワークスペースのREADME。古い段階の説明も含むため、現在判定は上記統合資料を優先 |
| [core/](core/) | Arduino非依存の通信・TDD・schedulerコア |
| [firmware/phase6/](firmware/phase6/) | R18系標準アダプタ・canonical bridge |
| [firmware/high_speed/](firmware/high_speed/) | R19高速化の実験用ソース |
| `vc_lora_*_xiao_*` | 製品スケッチのコピーと歴代診断スケッチ。すべてが現行・受入済みではない |
| [third_party/](third_party/) | ESP32 Core 3.3.11用の変更済みHWCDCソース |
| [tests/](tests/) / [tools/](tools/) | ホスト試験、診断、収集、評価、厳密な書込み・復旧ゲート |
| [runs/](runs/) | 今回の主要観測と比較用履歴。全履歴ではない |
| [publication/](publication/) | 公開範囲・整合性検査・今回のオフライン確認結果 |

## 接続と固定条件

```text
下り: Pixhawk TX → Vehicle D7 RX → Vehicle E220 → LoRa → Ground E220 → Ground XIAO → COM6 → PC
上り: PC → COM6 → Ground XIAO → Ground E220 → LoRa → Vehicle E220 → Vehicle D6 TX → Pixhawk RX
診断: COM3 = Vehicle USB CDC / COM6 = Ground USB CDC（製品MAVLinkと排他）
JTAG: 別USB機能。内部記録取得用であり、MAVLinkの通信経路ではない。
```

| 項目 | 現行固定値 |
|---|---|
| Pixhawk/GCS設定 | 57600 bps、8N1 |
| E220 UART | 115200 bps、8N1 |
| E220 profile | `00 00 E5 C3 46 00 00 00` |
| E220信号 | D0=M0、D1=M1、D2=TX、D3=RX、D8=AUX |
| Pixhawk信号 | D6=TX、D7=RX |
| USB完了条件 | 106 msを維持。無線仕様・MAVLink標準のtimeoutではない |

E220の印字型式・air rate・TDD設定を変更する場合は、対象候補の仕様・レジスタ証拠で確認してください。
図や過去資料の値だけで変更しないでください。

## 同梱した主な証拠

| 保存パス（本ディレクトリ基準） | 観測・目的 |
|---|---|
| `runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261020T223348550Z-ccb3f550/` | 40秒dual-COM、両role内部記録、R18復旧。各COMに診断2,646 byte／42 frame、製品frame 0。Ground初回USB完了106.238 ms失敗 |
| `runs/hil/E2E-MAV-CONNECTED-PASSIVE-RX-001/20261021T004656Z/` | 現接続状態の受信専用60秒、COM6受信0 byte |
| `runs/hil/CONNECTED-NO-POWER-CYCLE-JTAG-PREFLIGHT-001/20261021T013650Z/` | 電源再投入なしの接続確認。USB-JTAG接続のみPASS |
| `runs/validation/R19-STARTUP-LAYER-CUT-OFFLINE-001/20261021T001127260Z/` | PC準備workflow／境界判定器・関連試験。選別ログ |
| `runs/validation/R19-OFFLINE-READINESS-AND-RECURRENCE-REVIEW-001/20261021T012327Z/` | 0 byte再発履歴と未統合範囲の監査。選別ログ |
| `runs/validation/R19-CONTINUOUS-READER-AND-HOST-READINESS-OFFLINE-001/20261020T193032512Z/` | 連続読取り・準備状態のtest-first検証。選別ログ |
| `runs/hil/R19-RUNTIME-STAGE-CAUSE-EXPERIMENT-HIL-001/20261010T075800693Z-5ef10ffd/` | 過去R19のdual-COM 0 byteと比較 |
| `runs/hil/R18-PRODUCTION-SINGLE-PARAM-LIVENESS-HIL-001/` | 過去R18の0 byteと、その後の単一PARAM成功の2 run |
| `runs/hil/R18-READONLY-HEARTBEAT-BASELINE-001/` / `R18-PIXHAWK-READONLY-PREFLIGHT-HIL-001/` | 2026-09-25の比較用JSON |

日付付きrun名はUTCです。説明中の時刻は、特記がなければJSTです。
証拠の原本はbyte単位で保持しています。旧PCの絶対パス・USB個体識別情報は実験の来歴であり、新環境へのインストール先や秘密の認証情報ではありません。

## 再現できる範囲

Windows PowerShell 5.1またはPowerShell 7で、このディレクトリへ移動して実行する純オフライン試験の例です。
接続機器・APIキーは不要です。

```powershell
& './tests/hil/check_r19_host_readiness_workflow.ps1'
& './tests/hil/check_r19_startup_boundary_evaluation.ps1' -RepoRoot (Get-Location).Path
```

C++ホスト試験にはCMake 3.20以上、Ninja、C++17対応コンパイラが必要です。
元ワークスペースで保存済みの全host 345/345 PASSと、この公開コピーで今回実行した確認は別です。
**全345件のclean-clone再現を保証しません。** 一部の試験は今回省略した過去run・sealed candidateを参照します。欠測で失敗したテストを削除・緩和して合格としないでください。
今回このコピーで実行した項目・件数は[公開時検証記録](publication/VALIDATION.md)に記載します。

通常版Arduino buildにはXIAO ESP32-S3環境と所定の変更済みESP32 Core 3.3.11が必要です。
SDKへのインストール・COM操作・書込みを行うツールは純オフライン確認ではありません。
`AGENTS.md`・各runbookの条件を満たすまで実行しないでください。

## 今後の残作業

1. PC読取り準備、機器ARM受理、初回製品enqueue、USB完了を同じbuild／boot／USB epochで結合して記録する。
2. その固定記録をstrict decoder・manifest・JTAG取得へ統合し、mode別候補と専用live runnerを準備する。
3. 許可・安全条件・cold boot・復旧条件をそろえた実機比較で、準備前の失敗と準備後のUSB停止を切り分ける。
4. 診断成立後、別の製品経路受入で932件／30秒／Heartbeat／全error 0を同時評価する。

PowerShellは現時点ではPC側の開発・試験・証拠保存・復旧用です。
通常製品通信はMission PlannerがGroundのCOM6を直接使用し、PowerShellやJevを通信の中継には使用しません。
Jevは任意のPC側Shadow助言機能であり、製品の判定・実機操作権限を持ちません。

## 公開範囲と注意

- 元ワークスペース全体ではありません。巨大なbuild tree、全run履歴、Arduino compiler生成物、driver配布ZIP、APIキー、履歴・画面画像等は除外しました。
- raw診断の小さな`.bin`と、一部の過去R18 run内に保存されたaccepted application imageは、そのrunの証拠整合のため保持しています。
- R19のsealed candidate一式、復旧用baselineの完全な依存関係、ローカルtoolchainは同梱していません。**このcloneをそのまま実機書込み可能な認証済みパッケージとして扱わないでください。**
- 選別したvalidationのmanifestやsealは省略ファイルも参照し得ます。公開コピー全体の同梱範囲は`publication/source_inventory.json`で区別します。
- 変更済みEspressifファイルのライセンス・帰属は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照。プロジェクト全体への新しいライセンス付与は行っていません。
- GitHubへの公開・記載された過去の許可文言は、将来の実機操作・再試験の許可にはなりません。

元ソースと測定記録は保持し、公開に伴う製品コードの修正は行っていません。
