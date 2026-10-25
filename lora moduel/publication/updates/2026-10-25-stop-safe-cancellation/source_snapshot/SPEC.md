# VC_LoRa Pixhawk MAVLink Direct Bridge SPEC

## 目的

Pixhawk の MAVLink TELEMETRY を、E220-900T22S LoRa 2台と XIAO ESP32-S3 2台で無線化し、Mission Planner へ直接接続する。

今回の実装対象は UI なし、MAVProxy なし、UDP なしの直接 COM 接続である。

## システム範囲

対象:

- Pixhawk TELEM MAVLink の双方向透過
- E220-900T22S transparent mode
- Ground XIAO USB COM と Mission Planner の直接接続
- 別PCでも COM 番号を選び直すだけで動く構成

対象外:

- MAVProxy ルーティング
- UDP `14550` / `14555` 転送
- Route Monitor UI
- 本番MAVLink経路へのデバッグ文字列出力
- ブリッジ側の擬似 heartbeat 送信

## 構成

```text
Pixhawk TELEM
  <-> Vehicle XIAO ESP32-S3
  <-> Vehicle E220-900T22S
  )) 920 MHz LoRa transparent link ((
Ground E220-900T22S
  <-> Ground XIAO ESP32-S3
  <-> PC USB COM
  <-> Mission Planner
```

## ファームウェア

| 役割 | ファイル |
|---|---|
| Vehicle | `vc_lora_vehicle_xiao_esp32s3/vc_lora_vehicle_xiao_esp32s3.ino` |
| Ground | `vc_lora_ground_xiao_esp32s3/vc_lora_ground_xiao_esp32s3.ino` |
| 共通実装 | `core/include/vc_lora/`、`core/src/`、`firmware/phase6/vc_lora_phase6_bridge.hpp` |
| E220診断 | `vc_lora_ground_e220_diag_xiao_esp32s3/vc_lora_ground_e220_diag_xiao_esp32s3.ino` |

## 固定値

| 項目 | 値 |
|---|---|
| Pixhawk TELEM baud | `57600` |
| Ground USB COM baud | `57600` |
| XIAO <-> E220 UART baud | `115200` |
| XIAO <-> E220 UART format | `8N1` |
| E220 air data rate | `19.2 kbps` |
| E220 sub-packet / bridge chunk | `32 bytes` |
| E220 module | `E220-900T22S` |
| E220 channel | `0x46` |
| RF frequency | `920.125 MHz` |
| E220 mode | Normal transparent |

## E220 設定

両側で一致させる。

| Register | 値 | 意味 |
|---|---|---|
| ADDH/ADDL | `0x0000` | 同一アドレス |
| REG0 | `0xE5` | UART 115200、8N1、air 19.2 kbps |
| REG1 | `0xC3` | 32-byte sub-packet、10 dBm |
| REG2 | `0x46` | 920.125 MHz |
| REG3 | `0x00` | transparent |
| CRYPT | `0x0000` | 暗号なし |

本番設定8バイトは `00 00 E5 C3 46 00 00 00` とし、両側で完全一致させる。
本番ファームは起動時に設定を読み、相違時だけ永続設定を自動修正する。
`REG0=0xC8`（57600 / 8O1 / air 2.4 kbps）は使用しない。

production経路はCRC-validなcomplete MAVLink frameをXIAO RAMへqueueし、E220へ最大32 bytesの
物理writeへ分割して投入する。AUX=LOW中はE220へ書き込まない。50 ms partial flushは
legacy/raw互換定数であり、frame-aware production経路の送信判断には使わない。

## 半二重TDD仕様

E220単体試験で確認した最小500 msの方向転換時間を満たすため、次の周期で
送信方向を制限する。

| 区間 | 時間 | 動作 |
|---|---:|---|
| Vehicle送信 | 3000 ms | PixhawkからのMAVLinkをE220へ送信 |
| Vehicle受信 | 2000 ms | VehicleからのE220送信を停止 |
| Ground待機 | 無線受信停止後650 ms | Vehicle E220が受信状態になるまで待機 |
| Ground送信 | 300 ms | whole-frame transactionの承認／開始期限 |

Ground送信後からVehicle送信再開までにも500 ms以上の余裕を確保する。
E220からローカルUARTへの受信転送は両側とも全区間で継続する。

## MAVLink帯域制御

- 180 msは従来のminimum lower boundとし、productionでは550 ms service floorが支配する。
- 最新HILで観測したremote service間隔に合わせ、full UART write後550 msかつ
  AUX HIGH連続15 msを満たすまでradio busyを解除しない。
- 開始済みdescriptorは300 msを越えても550 ms pacingでDATA＋DONEまで有界完遂する。
- Vehicle側はMAVLink v1/v2の完全なフレーム境界を保持して転送する。
- heartbeatは最新1フレームを保持する専用優先スロットへ格納する。
- コマンド、ミッション、パラメータ応答は8フレームキューへ格納する。
- 姿勢、GPS、電源、EKFなどの表示用テレメトリは1 Hzに制限する。
- `msgid=194`を含むその他の低優先度フレームはフレーム全体を破棄し、
  途中バイトを無線へ混入させない。

## 将来仕様 FUTURE-FLOW-001：混雑追従・長距離リンク変動への対応

状態: 将来対応。今回の初回USB送信完了失敗の修正・実機受入対象には含めない。
既存の固定バッファ、優先度、AUXによる局所credit管理を廃止・未実装扱いするものではない。

目的は、距離そのものではなく、実効帯域の低下・変動、再送、一時的な送信停止、
入力burstによる滞留を有界に処理することである。有限バッファの増量だけで、
持続的な入力速度超過を解決したとはみなさない。

将来の統合要件:

- 固定容量・完全フレーム単位の受理を維持し、容量、最大使用量、drop、最古frame ageを記録する。
- 高水位で通常テレメトリ／bulk投入を抑制し、低水位で再開する。判定の往復による振動を避ける。
  閾値、制御対象、許容滞留時間は実測帯域と最大burstから算定し、未測定の数値を固定しない。
- Heartbeatとコマンド応答には独立した優先枠・deadlineを維持し、大量パラメータで飢餓させない。
- パラメータ／コマンドの欠落は成功扱いせず、相関ID・index・件数を使って明示的に検出・回復する。
- 抑制・再開・再送は受理済みpartial suffixを保持する。USBへ受理した全フレームを無条件に再送しない。
- AUXによる局所buffer空きと、相手へのRF到達・最終tail・GCS取得完了は別の証拠として扱う。
- 容量は入力burstと許容停止時間に加え、frame descriptorとdeadline制約を含めて評価する。
- 受入は帯域低下・送信停止・入力burst・混雑回復を注入し、優先通信の期限、欠落会計、
  永久待ちなし、回復後の順序・完全性を同時に評価する。机上容量計算だけでは合格しない。

今回の初回USB失敗記録はring／stashとも0のため、buffer増量が直接の原因修正である根拠はない。
106 ms、UART／TDD／E220設定、現行固定容量は本項の追記によって変更しない。

## ピン仕様

### XIAO ESP32-S3 と E220

| XIAO | E220 |
|---|---|
| `D0` | `M0` |
| `D1` | `M1` |
| `D2` | `RXD` |
| `D3` | `TXD` |
| `D8` | `AUX` |
| `GND` | `GND` |

### Vehicle XIAO ESP32-S3 と Pixhawk

| XIAO | Pixhawk TELEM |
|---|---|
| `D6` | `RX` |
| `D7` | `TX` |
| `GND` | `GND` |

## Mission Planner 接続仕様

- 接続方式: Serial COM
- COM: PC に表示される Ground XIAO の COM
- Baud: `57600`
- UDP は使わない
- MAVProxy は使わない

## 合格条件

- Mission Planner が Pixhawk heartbeat を継続受信する
- `sys=1 comp=1` の Pixhawk heartbeat が安定して見える
- パラメータ読み込みが進む
- 文字列ログや `[VC_LoRa]` などのデバッグ文字列が Mission Planner 側へ混入しない

## NG 判定

- 「ハートビートを1回だけ受信しました」で止まる
- heartbeat は来るが数秒で止まる
- Mission Planner がパラメータ読み込みへ進まない
- Serial raw はあるが valid MAVLink frame が増えない

## 備考

E220 設定診断コードは、E220 設定確認のために USB Serial へテキストを出す。診断コードを本番の MAVLink 経路として使用しないこと。
