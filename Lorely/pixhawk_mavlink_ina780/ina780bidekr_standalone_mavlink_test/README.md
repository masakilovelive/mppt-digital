# INA780BIDEKR Standalone MAVLink Test

`INA780BIDEKR_only_test.ino` はESP32-S3に接続したINA780を読み取り、Lorely3 UIと同じMAVLinkフィールドでUSB Serialへ送信します。

## Wiring

| ESP32-S3 | INA780 |
| --- | --- |
| `3.3V` | `VCC` |
| `GND` | `GND` |
| `GPIO8` | `SDA` |
| `GPIO9` | `SCL` |

| Address | Channel | MAVLink prefix |
| --- | --- | --- |
| `0x40` | `BATT` | `BATT_*` |
| `0x43` | `AUX_BATT` | `AUX_*` |
| `0x41` | `ESC` | `ESC_*` |
| `0x44` | `PV1` | `PV1_*` |
| `0x45` | `PV2` | `PV2_*` |

## Lorely3 UI

1. このスケッチをESP32-S3へ書き込みます。
2. `lorely3_hybrid_power_dashboard.py` を起動します。
3. `基地局 MAVLink` でESP32-S3のCOMポートと `115200` を選び、`接続` を押します。

起動時の既定動作はMAVLink送信です。UI接続時にも `m` を送信してMAVLinkモードへ切り替えます。単体USB接続には無線RSSIがないため、UIは `RSSI -- dBm` と表示します。

## Serial Commands

| Command | Operation |
| --- | --- |
| `m` | MAVLink送信モード、200 ms周期 |
| `a` | 全INA780のテキスト連続診断 |
| `1` to `5` | 個別チャンネルのテキスト診断 |
| `s` | I2Cスキャンをテキスト表示 |
