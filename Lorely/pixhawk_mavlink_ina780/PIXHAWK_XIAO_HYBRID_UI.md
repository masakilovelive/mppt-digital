# Pixhawk + XIAO ESP32-S3 ハイブリッド管理UI構成メモ

## 1. 目的

水中翼船・ハイブリッド電力管理システムにおいて、Pixhawk、VESC、INA780、PVセンサ、音声案内、Mission Planner、オリジナルUIを連携させる。

本READMEでは、これまで検討した内容を以下の観点で整理する。

- PixhawkとMission Plannerの同時利用
- 管理用 XIAO ESP32-S3 の役割
- 音声用 XIAO ESP32-S3 の役割
- UART / CAN の割り当て
- VESC CAN通信
- ESP-NOW / Web UI / 基地局表示
- Pixhawk SDカードへのログ保存方法
- デバッグ手順

---

## 2. 全体構成の基本方針

Pixhawkは航法・姿勢制御・安全系を担当し、管理用 XIAO ESP32-S3 が電力・推進・UI・ログ中継を担当する。

```text
Mission Planner / PC
        ↑ USB-C / MAVLink
        │
┌───────┴────────┐
│    Pixhawk      │
│ 航法・姿勢・安全 │
└───────┬────────┘
        │ UART / MAVLink
        ▼
┌────────────────────┐
│ 管理用 XIAO ESP32-S3 │
│ エネルギー管理ECU     │
└─┬─────┬─────┬─────┬──┘
  │     │     │     │
 CAN   I2C   UART  Wi-Fi/ESP-NOW
  │     │     │     │
 VESC  INA780 音声XIAO 基地局/独自UI
```

---

## 3. 役割分担

### 3.1 Pixhawk

担当内容：

- 姿勢制御
- GPS / 船体状態管理
- RC受信機入力
- フェイルセーフ
- Mission Planner接続
- DataFlash / BINログ
- MAVLink通信

Mission Plannerは基本的に Pixhawk の USB-C または TELEM で接続する。

試作・デバッグ段階では、Mission PlannerはUSB-C接続が最も扱いやすい。

---

### 3.2 管理用 XIAO ESP32-S3

担当内容：

- PixhawkからMAVLink受信
- VESCからCANまたはUARTで推進データ取得
- INA780からI2Cで電圧・電流・電力取得
- PVセンサ値の取得
- 電力フロー計算
- ハイブリッドモード判定
- 音声用XIAOへのUARTコマンド送信
- ESP-NOWまたはWi-Fiで基地局へ送信
- Web UI / 独自UI用データ生成
- 必要に応じてPixhawkへMAVLink再送信
- 必要に応じてローカルSDへCSV保存

管理用XIAOは、システム全体の「エネルギーマネジメントECU」として扱う。

---

### 3.3 音声用 XIAO ESP32-S3

担当内容：

- WAV再生
- 起動音
- 警告音
- 状態音声案内
- I2Sアンプ制御
- 管理用XIAOからのUARTコマンド受信

推奨構成：

```text
管理用 XIAO ESP32-S3
        │ UART
        ▼
音声用 XIAO ESP32-S3
        │ I2S
        ▼
MAX98357A 等 I2Sアンプ
        │
        ▼
スピーカー
```

音声再生はSDアクセスやI2S処理で負荷がかかるため、管理用と音声用を分離する構成が安全。

---

## 4. UART構成

### 4.1 推奨割り当て

```text
Pixhawk
├─ USB-C      → Mission Planner
├─ TELEM1/2   → 管理用 XIAO ESP32-S3
├─ 予備UART    → STM32姿勢制御モジュール
└─ RC IN / UART → ELRS/CRSF/SBUS等

管理用 XIAO ESP32-S3
├─ UART → Pixhawk
├─ UART → 音声用 XIAO ESP32-S3
├─ CAN  → VESC
├─ I2C  → INA780
└─ SPI  → SDカード等
```

### 4.2 Mission PlannerはUSB-C推奨

Mission PlannerをUSB-C接続にすると、PixhawkのUARTを消費しない。

```text
PC / Mission Planner
        ↑ USB-C
        │
      Pixhawk
        │ TELEM
        ▼
管理用 XIAO ESP32-S3
```

この構成により、PixhawkのUART不足は起きにくい。

---

## 5. Pixhawk TELEMポートの基本ピンアサイン

Pixhawk系のTELEM 6pin JST-GHは一般に次の並び。

| Pin | 信号 | 内容 |
|---:|---|---|
| 1 | 5V | 電源出力 |
| 2 | TX | Pixhawk送信 |
| 3 | RX | Pixhawk受信 |
| 4 | CTS | フロー制御 |
| 5 | RTS | フロー制御 |
| 6 | GND | GND |

XIAO ESP32-S3との基本接続：

```text
Pixhawk TX → XIAO RX
Pixhawk RX → XIAO TX
Pixhawk GND → XIAO GND
```

最初はCTS/RTSなしでよい。

注意：機種・キャリアボード・ロットによりピン位置の見え方が異なるため、実配線前に必ず対象機体の公式ピンアウト図で確認する。

---

## 6. Pixhawk V6X / Pixhawk 6C での実現性

### 6.1 Pixhawk V6X

Pixhawk V6Xでも実現可能。

想定割り当て：

```text
Pixhawk V6X
├─ USB-C  → Mission Planner
├─ TELEM1 → 管理用 XIAO ESP32-S3
├─ TELEM2 → 予備 / STM32 / LTE
├─ CAN    → DroneCAN機器用
└─ RC IN  → 受信機
```

V6XはUART数に余裕があり、管理用XIAO、STM32、将来LTE等を分離しやすい。

### 6.2 Pixhawk 6C

Pixhawk 6Cでも実現可能。

想定割り当て：

```text
Pixhawk 6C
├─ USB-C  → Mission Planner
├─ TELEM1 → 管理用 XIAO ESP32-S3
├─ TELEM2 → STM32姿勢制御 / 予備
└─ RC IN  → 受信機
```

今回の構成では、Mission PlannerをUSB-Cに逃がせるため、Pixhawk 6CでもUART不足になりにくい。

---

## 7. XIAO ESP32-S3背面パッドの利用

XIAO ESP32-S3は側面ピンだけでなく、背面パッドも配線に利用できる。

用途候補：

- 追加UART
- CAN/TWAI TX/RX
- I2C
- SPI
- GND
- 電源系

### 7.1 背面パッド使用例

```text
背面GPIO 2本 → CAN TX/RX
背面GPIO 2本 → 音声XIAO用 UART TX/RX
側面GPIO     → Pixhawk MAVLink UART / I2C / SPI
```

### 7.2 注意点

背面パッドは小さく、ランド剥離しやすい。

推奨：

- 30AWG程度の細線
- 低温・短時間ではんだ付け
- UVレジンまたはホットボンドで固定
- 外部回路で強いPull-Up/Pull-Downを入れない
- 起動ストラップピンとして使われるGPIOは特に注意

量産・長時間運用では、XIAOを載せる専用キャリア基板を作るのが望ましい。

---

## 8. XIAO ESP32-S3 と VESC の CAN通信

XIAO ESP32-S3とVESCのCAN通信は可能。

ただしESP32-S3内蔵のCAN機能はTWAIコントローラであり、CANトランシーバは外付けが必要。

推奨構成：

```text
XIAO ESP32-S3
   │ TWAI TX/RX
   ▼
SN65HVD230等 3.3V CANトランシーバ
   │ CANH / CANL
   ▼
VESC CAN
```

### 8.1 推奨CANトランシーバ

ESP32-S3は3.3V系なので、最初は以下が扱いやすい。

- SN65HVD230
- SN65HVD232
- 3.3V対応CANトランシーバモジュール

TJA1050やMCP2551は5V系のため、ESP32-S3と直結する場合はロジック電圧に注意する。

### 8.2 VESC CANとDroneCANの違い

重要：

```text
VESC CAN ≠ DroneCAN
```

物理層はどちらもCANだが、プロトコルが異なる。

そのため、PixhawkのCANポートにVESCを直接つないでも、そのままVESCデータを読めるとは限らない。

今回の推奨は：

```text
VESC CAN → 管理用XIAO → MAVLink/ESP-NOW/WebUI
```

---

## 9. ESP-NOW / Web UI / 基地局送信

管理用XIAOは、Pixhawk情報、VESC情報、INA780情報、PV情報を集約して基地局へ送信できる。

```text
Pixhawk → UART/MAVLink → 管理XIAO
VESC    → CAN          → 管理XIAO
INA780  → I2C          → 管理XIAO
PV      → I2C/ADC      → 管理XIAO

管理XIAO → ESP-NOW / Wi-Fi → 基地局XIAO / PC / iPhone / Web UI
```

### 9.1 Mission Plannerと独自UIの分担

```text
Mission Planner = 航法・姿勢・設定・安全確認
独自UI          = 電力フロー・VESC・PV・ハイブリッド管理
```

この分担が最も安全。

初期段階では、独自UIは読み取り専用にする。

---

## 10. Pixhawk SDカードへログ保存する方法

### 10.1 まず区別するログ

ArduPilot系では、ログには大きく2種類ある。

| 種類 | 保存場所 | 内容 |
|---|---|---|
| DataFlash / BINログ | Pixhawk側SDカード等 | Pixhawkが内部的に記録するログ |
| Telemetry Log / tlog | PC側 Mission Planner等 | MAVLinkテレメトリをPCが保存するログ |

USB-CでPixhawkをPCに接続しMission Plannerで確認している場合、PC側にはテレメトリログを残せる。

一方、PixhawkのSDカード内のBINログへ、外部XIAOの独自センサ値を確実に入れるには、設計が必要。

---

### 10.2 方法A：PC側tlogに残す

最も簡単。

```text
管理XIAO → Pixhawk/または直接GCS → MAVLink
Pixhawk USB-C → Mission Planner
Mission Planner → tlog保存
```

確認用にはこの方法が簡単。

ただし、PixhawkのSDカード内BINログとは別物。

---

### 10.3 方法B：Pixhawk SDカードにLuaでログを書く

ArduPilot Lua Scriptを使い、Pixhawk側でUARTまたはMAVLinkから値を受け取り、Luaからログへ書く方法。

概念：

```text
管理XIAO
   ↓ UART / MAVLink
Pixhawk Lua Script
   ↓ logger:write 相当
Pixhawk SD / BINログ
```

この方式はPixhawkファームウェア本体の改造を避けられる可能性がある。

実装方針：

- 管理XIAOが短いCSV/バイナリ/簡易プロトコルでPixhawkへ送信
- Pixhawk側LuaがSERIALポートから受信
- LuaがDataFlashログへ独自ログ名で保存

例ログ名：

```text
HYB  : Hybrid status
PV   : PV power
VESC : VESC state
PWR  : DC link / battery power
VOC  : voice event
```

注意：Luaスクリプトの対応可否はArduPilotのバージョン、機体種別、メモリ、SERIAL設定に依存する。

---

### 10.4 方法C：ArduPilotファームウェアを改造してログ追加

最も確実だが難易度は高い。

```text
管理XIAO → MAVLink custom message → ArduPilot側で受信処理追加 → AP_Loggerへ保存
```

メリット：

- BINログにきれいに入る
- Mission PlannerやMAVExplorerで扱いやすい
- 量産・研究用途で再現性が高い

デメリット：

- ArduPilotビルド環境が必要
- カスタムMAVLink定義が必要
- ファームウェア更新管理が必要

---

### 10.5 方法D：標準MAVLinkメッセージに寄せる

独自値を標準メッセージに寄せる方法。

候補：

- BATTERY_STATUS
- ESC_TELEMETRY
- ESC_STATUS
- NAMED_VALUE_FLOAT
- STATUSTEXT
- DEBUG_FLOAT_ARRAY

ただし、標準MAVLinkをPixhawkへ送っただけで、すべてがPixhawkのSDカードBINログに自動保存されるとは限らない。

用途の目安：

| メッセージ | 用途 |
|---|---|
| STATUSTEXT | Mission PlannerのMessages確認向け |
| NAMED_VALUE_FLOAT | 簡易値表示・デバッグ向け |
| BATTERY_STATUS | 電源系として扱う場合の候補 |
| ESC_TELEMETRY | ESC/VESC相当値の候補 |
| custom MAVLink | 最終的な独自システム向け |

---

### 10.6 ログ保存の推奨順

試作段階：

```text
1. 管理XIAOのローカルSDへCSV保存
2. Mission PlannerのtlogでMAVLink確認
3. STATUSTEXT / NAMED_VALUE_FLOATで表示確認
4. Pixhawk LuaでSD/BINログ化
5. 必要ならArduPilot改造で正式ログ化
```

最初からPixhawk SDログに完全統合するより、まず管理XIAO側で確実にログを取る方が安全。

---

## 11. 音声データ確認とセンサ送信確認

音声コマンドの確認は、管理XIAOの送信確認にもなる。

```text
管理XIAO → UART → 音声XIAO
```

で、たとえば以下を送る。

```text
TEST
LOW_BATTERY
GPS_LOST
RTL_START
PV_MODE
```

音声XIAO側の確認ログ：

```text
[RX] LOW_BATTERY
[PLAY] low_battery.wav
```

この確認が成功すれば、管理XIAOからのUART送信、パケット生成、イベント生成が動いていることになる。

同じ仕組みで、後から以下のようなセンサ値も送れる。

```json
{
  "pv1_w": 320,
  "pv2_w": 280,
  "soc": 78,
  "vesc_rpm": 1800,
  "mode": "PV_ASSIST"
}
```

---

## 12. PCでの確認方法

### 12.1 Pixhawk USB-Cで確認

```text
管理XIAO → Pixhawk → USB-C → PC / Mission Planner
```

確認できるもの：

- MAVLink受信状態
- STATUSTEXT
- NAMED_VALUE_FLOAT
- 一部センサ値
- Mission Planner Messages
- MAVLink Inspector
- tlog
- DataFlash/BINログの有無

### 12.2 音声コマンド確認

管理XIAOが音声イベント発生時に、同時にPixhawkへSTATUSTEXTを送ると便利。

例：

```text
VOICE: LOW_BATTERY
VOICE: GPS_LOST
VOICE: RTL_START
```

Mission PlannerのMessagesで見えるため、音声が鳴らなくてもイベント発生を確認できる。

---

## 13. 推奨デバッグ順

### Step 1：音声XIAO単体

- SDカード内WAV再生
- I2Sアンプ確認
- スピーカー確認

```text
TEST → test.wav
```

### Step 2：管理XIAO → 音声XIAO UART

- 文字列受信確認
- LED点滅
- シリアルモニタ表示
- 対応WAV再生

### Step 3：Pixhawk → 管理XIAO MAVLink

- HEARTBEAT受信
- ATTITUDE受信
- GPS受信
- BATTERY_STATUS受信

Pixhawk 6C と XIAO ESP32-S3 のUART疎通だけを先に確認する場合は、以下の専用テストを使う。

```text
pixhawk6c_xiao_esp32s3_uart_mavlink_test/
```

このテストでは、XIAO側でPixhawkのHEARTBEATを受信し、XIAOからPixhawkへ `MAV_CMD_SET_MESSAGE_INTERVAL` を送って双方向通信を確認する。

### Step 4：VESC → 管理XIAO CAN

- RPM
- 入力電圧
- モータ電流
- Duty
- 温度
- Fault

### Step 5：INA780 / PV取得

- 電圧
- 電流
- 電力
- PV1/PV2
- DCリンク

### Step 6：管理XIAO → 基地局

- ESP-NOW
- Web UI
- JSON送信
- 電力フロー表示

### Step 7：管理XIAO → Pixhawkへイベント送信

- STATUSTEXT
- NAMED_VALUE_FLOAT
- 必要に応じてLuaログ

### Step 8：Pixhawk SDログ確認

- LOG_DISARMED設定確認
- BINログ生成確認
- Mission Plannerでダウンロード
- MAVExplorer / Mission Plannerで確認

---

## 14. 実装時の注意点

### 14.1 電圧レベル

- Pixhawk UART信号は3.3V系として扱う
- ESP32-S3も3.3V系
- 5V電源線と信号線を混同しない
- GND共通必須

### 14.2 CAN

- CANH/CANLはツイストペア推奨
- 終端抵抗120Ωはバス両端に配置
- XIAOのすぐ近くにCANトランシーバを置く
- VESC CANとDroneCANを混同しない

### 14.3 SDカード

- Pixhawk SDログとXIAOローカルSDログは別物
- 実験初期はXIAO側CSVログも残す
- Pixhawk SDへ入れる場合はLuaまたはファーム側ログ処理を検討する

### 14.4 UI

初期段階では読み取り専用にする。

制御指令を出す場合は、Mission Planner、Pixhawk、管理XIAOの責任範囲を明確化する。

---

## 15. 最終推奨構成

```text
                  ┌─────────────────┐
                  │ Mission Planner  │
                  │ PC / USB-C       │
                  └────────▲────────┘
                           │ MAVLink
                           │
                  ┌────────┴────────┐
                  │     Pixhawk      │
                  │ 航法・姿勢・安全 │
                  │ SD/BINログ       │
                  └────────┬────────┘
                           │ UART/MAVLink
                           ▼
              ┌────────────────────────┐
              │ 管理用 XIAO ESP32-S3    │
              │ Energy Management ECU   │
              └─┬──────┬──────┬──────┬─┘
                │      │      │      │
              CAN     I2C    UART   ESP-NOW/Wi-Fi
                │      │      │      │
              VESC   INA780  音声XIAO 基地局/独自UI
                              │
                              ▼
                         I2Sアンプ
                              │
                              ▼
                         スピーカー
```

---

## 16. 現段階の結論

- XIAO ESP32-S3を2個使う構成は合理的。
- 管理用XIAOと音声用XIAOを分けることで、UI・通信・音声処理の負荷を分離できる。
- PixhawkのUARTは、Mission PlannerをUSB-Cにすることで不足しにくい。
- VESCはPixhawk CANへ直接ではなく、管理XIAOのCAN/TWAI経由で読むのが現実的。
- ESP-NOW/Web UIで独自管理画面を作れる。
- Pixhawk SDカードへ外部センサ値を確実に保存するには、LuaログまたはArduPilot側のログ処理が必要。
- 最初は、管理XIAOローカルSD + Mission Planner tlog + STATUSTEXT表示で検証し、その後Pixhawk SD/BINログ統合へ進むのが安全。
