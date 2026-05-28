# Lorely3 Pixhawk / MAVLink / INA780 Integration

このディレクトリは、Lorely3 の航法系、電力監視系、基地局監視系を接続するための資料と確認用スケッチをまとめたものです。

対象は以下です。

- Pixhawk 6C / V6X と XIAO ESP32-S3 の UART MAVLink 疎通
- INA780BIDEKR による主電源、補助電源、VESC入力、PV1、PV2 の電力監視
- ESP-NOW 監視専用リンクから USB Serial MAVLink へ変換する基地局ブリッジ
- Mission Planner / QGroundControl / 独自UIで確認するための `NAMED_VALUE_FLOAT` 出力

## 構成方針

Pixhawk は航法、姿勢、安全、フェイルセーフを担当し、管理用 XIAO ESP32-S3 は電力、VESC、INA780、PV、独自UI、ログ中継を担当します。

```text
Mission Planner / PC
  -> USB-C / MAVLink
  -> Pixhawk
  -> TELEM UART / MAVLink
  -> 管理用 XIAO ESP32-S3
     -> I2C / INA780BIDEKR x5
     -> TWAI + SN65HVD230 / VESC CAN
     -> ESP-NOW / 基地局 XIAO ESP32-C3
     -> USB Serial MAVLink / PC UI
```

ESP-NOW 経路は監視専用です。Pixhawk、RC、推進、停止、操舵の制御には使いません。

## 収録ファイル

| Path | 内容 |
|---|---|
| `PIXHAWK_XIAO_HYBRID_UI.md` | Pixhawk、Mission Planner、管理用XIAO、VESC CAN、INA780、音声XIAO、ログ方針の統合メモ |
| `pixhawk6c_xiao_esp32s3_uart_mavlink_test/` | Pixhawk 6C TELEM と XIAO ESP32-S3 の双方向 MAVLink 確認スケッチ |
| `espnow_ina780_vesc_mavlink_bridge/` | 船体側 INA780 + VESC CAN 送信機と、基地局側 MAVLink ブリッジ |
| `ina780bidekr_standalone_mavlink_test/` | INA780BIDEKR 単体を USB Serial MAVLink で出す確認スケッチ |

## MAVLink フィールド

初期段階では標準メッセージの `NAMED_VALUE_FLOAT` を使います。name は MAVLink 制約に合わせて10文字以内に収めます。

| Name | 内容 |
|---|---|
| `BATT_V/I/P/T` | 主バッテリー電圧、電流、電力、温度 |
| `AUX_V/I/P/T` | 補助供給または MAP-300 系統 |
| `ESC_V/I/P/T` | VESC / 負荷入力 |
| `PV1_V/I/P/T` | 前方PV |
| `PV2_V/I/P/T` | 後方PV |
| `INA_MASK` | 有効な INA780 チャンネルのビットマスク |
| `CAN_OK` | VESC CAN status が有効なら `1` |
| `CAN_AGE` | 最終 VESC status 受信からの経過 ms |
| `VESC_RPM` | VESC electrical RPM |
| `VESC_IIN` | VESC input current |
| `VESC_VIN` | VESC input voltage |
| `VESC_PWR` | VESC input power |
| `RSSI` | ESP-NOW 受信RSSI |
| `RX_DT` | 受信周期 ms |
| `LOSS` | 推定欠落数 |
| `FAULT` | 欠落、VESC stale、TWAI failure 等のフラグ |

## INA780 アドレス

| Address | Channel | MAVLink prefix |
|---|---|---|
| `0x40` | `BATT` | `BATT_*` |
| `0x43` | `AUX_BATT` | `AUX_*` |
| `0x41` | `ESC` | `ESC_*` |
| `0x44` | `PV1` | `PV1_*` |
| `0x45` | `PV2` | `PV2_*` |

## 推奨確認順

1. `ina780bidekr_standalone_mavlink_test` で I2C アドレス、メーカーID、電力値、`INA_MASK` を確認する。
2. `pixhawk6c_xiao_esp32s3_uart_mavlink_test` で Pixhawk TELEM と XIAO の `HEARTBEAT` / `COMMAND_ACK` を確認する。
3. `espnow_ina780_vesc_mavlink_bridge` の基地局XIAO単体で USB Serial MAVLink 出力を確認する。
4. 船体側ESP32-S3を接続し、ESP-NOWの `RSSI`、`RX_DT`、`LOSS` をログする。
5. VESC CAN を接続し、`CAN_OK`、`CAN_AGE`、`VESC_*` が安定することを確認する。
6. Mission Planner / QGroundControl / Lorely3 UI で表示とCSVログを確認する。

## 安全境界

- Mission Planner は Pixhawk USB-C 接続を基本とし、Pixhawk TELEM は管理用 XIAO との MAVLink に割り当てる。
- VESC CAN と DroneCAN は別プロトコルとして扱う。VESC は管理用 XIAO の TWAI 経由で監視する。
- INA780 は連続監視とログに使い、切替瞬間の数百 us から数 ms の電圧ディップはオシロスコープまたは高速DAQで測る。
- Pixhawk SD / BIN ログへ外部センサ値を確実に入れる場合は、Lua ログまたは ArduPilot 側ログ処理を別途設計する。
