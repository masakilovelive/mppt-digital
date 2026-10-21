# 公開コピーの確認結果

実行日：2026-10-21。対象はこのリポジトリの `lora moduel` 公開コピーです。
製品コードは変更せず、元ワークスペースを参照せずに実行できる項目を選んで確認しました。

## 同梱内容の整合性・秘密情報

- 元ソース672ファイルと、履歴・測定証拠435ファイルのSHA-256を比較し、欠落・改変0でした。元の`README.md`だけを`PROJECT_README.md`へ改名しています。
- 追加物は公開用README・図解・属性設定・ライセンス全文・公開記録です。既存のhash固定ソースや測定原本は編集していません。
- 初回コピー1,108ファイルについて、テキストとraw `.bin`を秘密情報パターンで監査し、実APIキー・PAT・秘密鍵・認証付きURLの検出0、読取不能0でした。
- USB個体識別情報・過去のローカルパスは、秘密の認証情報ではなく測定の来歴として保持しています。
- 50 MB以上のファイル0。build tree、EXE、DLL、ELF、MAP、driver ZIP、cacheを含めていません。
- `source_inventory.json`は公開記録自身を除くグループごとの件数・byte数・SHA-256 treeと重要ファイルhashを記録します。
- `.gitattributes`でGitの改行正規化を無効にし、hash固定ソースと測定原本のbyte列を保持します。

## 今回再実行したオフライン試験

| 項目 | 実行環境 | 結果 |
|---|---|---|
| 受信準備workflow | Windows PowerShell 5.1 | 272/272 PASS |
| 起動境界classifier | Windows PowerShell 5.1 | 54/54 PASS |
| 受信準備workflow | PowerShell 7 | 272/272 PASS |
| 起動境界classifier | PowerShell 7 | 54/54 PASS |
| core・host・対象診断C++のbuild | CMake/Ninja/Clang | PASS、75 build steps |
| 準備状態・時計同期・初回失敗記録のC++ CTest | 同上 | 3/3 PASS |
| 自己完結coreケース（control・buffer・link・accounting・MAVLink境界） | 同上、直接実行 | 44/44 PASS |

C++の3 CTestはそれぞれ1,171、521、30 checksです。CTest件数とassertion/check件数は別です。
`lora moduel`の空白を含むパスで実行できることも確認しました。
完全な結果・バージョン・ログ一覧は[validation/summary.json](validation/summary.json)、
各coreケースの結果は[validation/cpp-cases/](validation/cpp-cases/)を参照してください。

初回CMake configureは、コンパイラパスのbackslashをCMakeが`\U`として解釈し失敗しました。
パスをforward slashにして別のbuild先で成功しており、失敗ログも保持しています。
長いobject pathのwarningはありますが、選択した対象のbuild・実行は成功しました。警告なしとはしていません。

## 判定限界

- 元ワークスペースで記録された全host 345/345 PASSは、今回の全件再実行結果ではありません。
- この公開コピーで全345件のclean-clone再現は保証しません。省略した履歴・sealed candidateを要求するテストがあります。
- COM、JTAG、書込み、reset、無線送信、API/Jev呼出しは今回実行していません。
- 上記PASSは、USB/LoRa実通信の復旧、932件30秒、Heartbeat SLA、実機受入を証明しません。
- validationログ中の絶対パスや一部相対パスは、公開時の検証作業場所を示す来歴です。
- 今回のGit公開操作は元のファームウェア・測定結果を修正していません。
