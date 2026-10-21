# 通信問題のシーケンス図

2026-10-21時点。異なる試験を3図に分け、観測済みの事実と未観測の経路を区別します。
「データ受理」「USB送出完了」「PC受信」「無線到達」「全パラメータ取得」は別の判定です。

## 1. 現接続状態の60秒受信確認

```mermaid
sequenceDiagram
    participant P as Pixhawk
    participant V as Vehicle XIAO / E220
    participant G as Ground E220 / XIAO
    participant C as PC / COM6
    Note over P,G: 設計上の下り経路は Pixhawk → Vehicle → LoRa → Ground<br/>今回、各中間境界の動作は未観測
    C->>G: COM6を開く（57600設定、DTR/RTS false）
    Note over C: 60.011493秒、受信処理を実行
    Note over G,C: PC受信0 byte・PC送信0 byte
    C->>G: Close / Dispose
    Note over P,C: 停止位置は未特定。搭載ファームhashも今回未照合
```

受信0 byteは実測ですが、RF部分やUSB FIFOの特定位置に停止印を置ける証拠はありません。
この試験はCOM3を開かず、書込み・JTAG・payload送信・reset要求を行っていません。

## 2. 過去R19：Groundの初回Heartbeat完了条件失敗

```mermaid
sequenceDiagram
    participant A as Ground製品処理
    participant Q as Local Egress
    participant U as HWCDC / USB内部
    participant H as PC受信処理
    A->>Q: 初回Heartbeat（21 byte）
    Q->>U: writeTxChecked
    U-->>Q: 21/21 byteを受理
    Note over U,H: ライブラリ受理 ≠ 21 byteのPC到達
    A->>U: USB送出完了を確認（106 ms条件）
    U-->>A: 完了条件を満たさず、106.238 msで失敗
    Note over A: runtime fail-closedをラッチ
    Note over A,U: 初回失敗の固定記録：ring 0 / stash 0<br/>publish generation 3 / pickup generation 2
    Note over U,H: ソフト待ち量0 ≠ Endpoint FIFO空<br/>USB内部のどの条件が先に不成立かは未確定
    U-->>H: 同じ試験の別観測：R19F等の診断データを受信
    Note over A,H: 診断受信は製品Heartbeat到達の証明ではない<br/>PC時計とMCU時計の精密な順序対応は未確定
```

このrunは各COMで2,646 byte・42完全診断frameを取得しましたが、製品frameは0件です。
後から取得したFIFO状態を、初回失敗時点のFIFO状態に置き換えてはいけません。
試験終了時にはaccepted R18へ復旧していますが、この事実だけで復旧後の通信成立まで証明したとは扱いません。

## 3. 最新USB-JTAG接続確認

```mermaid
sequenceDiagram
    participant PC as PC / OpenOCD
    participant V as Vehicle USB-JTAG
    participant G as Ground USB-JTAG
    PC->>V: 指定個体・USB locationを照合して接続
    V-->>PC: 接続確認PASS
    PC->>V: 明示shutdown・process終了
    PC->>G: 指定個体・USB locationを照合して接続
    G-->>PC: 接続確認PASS
    PC->>G: 明示shutdown・process終了
    Note over PC,G: CPU halt / system reset命令、RAM読取り、flash、COM openは未実施<br/>TAP初期化・clock・scan等の影響は未評価
    Note over PC,G: PASSはデバッグ用USB接続のみ<br/>CPU実行・MAVLink・無線・原因解消は未評価
```

結論：現在はPC受信0 byte。過去R19にはUSB完了待ち失敗の証拠がありますが、今回と同一原因かは未確定です。
JTAG接続成功は通信復旧の証明ではありません。
