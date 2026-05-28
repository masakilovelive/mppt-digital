# ESP-NOW INA780 + VESC CAN MAVLink Bridge

目的:

```text
船体 ESP32-S3 + INA780BIDEKR x 5 + SN65HVD230 / VESC CAN
  -> ESP-NOW 2.4GHz, monitor-only, 5Hz
  -> 基地局 XIAO ESP32-C3 + 外部アンテナ
  -> USB Serial MAVLink 115200
  -> Lorely3 Hybrid Power Flow Dashboard / PC監視UI
```

Pixhawk / RCの2.4GHz通信を最優先にするため、この経路は監視専用です。制御、停止、操舵、推進には使いません。

## Files

- `boat_esp32s3_ina780_sender/boat_esp32s3_ina780_sender.ino`
  - INA780をI2Cで読み、VESC CAN statusをTWAIで受信し、ESP-NOWで送信
- `base_xiao_esp32c3_mavlink_bridge/base_xiao_esp32c3_mavlink_bridge.ino`
  - ESP-NOWを受信し、INA780値とVESC値をMAVLink `NAMED_VALUE_FLOAT` としてUSB Serialへ出力

## VESC CAN wiring

カメラを使用しないESP32-S3構成で、船体側のCAN接続は以下とする。

| ESP32-S3 | SN65HVD230 | Purpose |
| --- | --- | --- |
| 3.3V | VCC | Transceiver power |
| GND | GND | Common ground |
| GPIO1 | TXD / CTX | CAN TX |
| GPIO2 | RXD / CRX | CAN RX |
| - | CANH | VESC CANH |
| - | CANL | VESC CANL |

スケッチ定義:

```cpp
static constexpr gpio_num_t CAN_TX_PIN = GPIO_NUM_1;
static constexpr gpio_num_t CAN_RX_PIN = GPIO_NUM_2;
static constexpr uint8_t TARGET_VESC_CAN_ID = 0x78;
```

VESC Toolで、CAN速度 `500 kbps` と `STATUS`, `STATUS_4`, `STATUS_5` の定期送信を有効にする。VESC CAN IDが `0x78` 以外の場合は `TARGET_VESC_CAN_ID` を変更する。

VESCのbroadcastを監視する構成であり、推進コマンドは送信しない。TWAIノードとしてCANバスのACKには参加する。

## Channel

両方のスケッチで同じ値にします。

```cpp
static constexpr uint8_t ESPNOW_CHANNEL = 1;
```

混信確認では `1`, `6`, `11` を比較します。

## INA780 wiring and addresses

船体側スケッチで変更します。

```cpp
static constexpr uint8_t I2C_SDA_PIN = 8;
static constexpr uint8_t I2C_SCL_PIN = 9;
```

| ESP32-S3 | INA780BIDEKR | Purpose |
| --- | --- | --- |
| 3.3V | VCC | Sensor power |
| GND | GND | Common ground |
| GPIO8 | SDA | I2C data |
| GPIO9 | SCL | I2C clock |

全センサは同じI2Cバスへ接続し、アドレスを以下の用途に割り当てます。

| Address | Name | UI use |
| --- | --- | --- |
| `0x40` | `BATT` | 主バッテリー電圧、電流、温度、電力 |
| `0x43` | `AUX_BATT` | MAP-300 / 補助供給の電力 |
| `0x41` | `ESC` | VESC / 電子負荷へ供給される実測電力 |
| `0x44` | `PV1` | 前方PV供給電力 |
| `0x45` | `PV2` | 後方PV供給電力 |

船体スケッチはINA780のメーカーID `0x5449` を確認したチャンネルだけを有効値として送信します。INA780の内部変換値を使うため、INA226用のシャント抵抗設定は不要です。

初期値の `REQUIRED_INA780_MASK = 0x00` は部分配線での動作確認用です。5系統すべてを必須として欠落を `FAULT` に反映する本試験では `0x1F` に変更します。

## PC monitor / Lorely3 UI

1. XIAO ESP32-C3へ `base_xiao_esp32c3_mavlink_bridge.ino` を書き込み
2. ESP32-S3へ `boat_esp32s3_ina780_sender.ino` を書き込み
3. PCで Lorely3 Hybrid Power Flow Dashboard を起動
4. 画面上部の `基地局 MAVLink` でXIAOのCOMポート、`115200` を選択し、`接続`

この接続だけでVESC CAN値とINA780実測電力を同時にUIへ反映します。

INA780単体確認もMAVLinkで行います。`../ina780bidekr_standalone_mavlink_test/INA780BIDEKR_only_test.ino` をESP32-S3へ書き込み、USB COMポートをUIの `基地局 MAVLink` で選択して `接続` します。単体スケッチは起動後から200 ms周期でMAVLinkを送信し、UI接続時にも `m` コマンドでMAVLinkモードへ復帰します。無線経路を通らないため、この場合の `RSSI` は `-- dBm`、通信状態は `受信中` と表示されます。

画面の `INA780 テキスト診断` 接続は、単体スケッチの従来形式の診断出力を確認する場合だけ使用します。接続時に `a` コマンドを送信してテキスト診断モードへ切り替えます。

通信値の個別診断には、MAVLink `HEARTBEAT` / `NAMED_VALUE_FLOAT` / `STATUSTEXT` を読める任意のモニタを利用できる。ただし、同一COMポートは同時に一つのアプリだけが開ける。

Lorely3 UIは基地局行に `RSSI`、`周期`、`欠落`、`通信` を表示します。`RSSI` はESP-NOW受信信号強度、`周期` は受信間隔、`欠落` は起動後の推定累積欠落数です。

| Communication display | Condition |
| --- | --- |
| `良好` | RSSIを取得でき、`-75 dBm` 以上かつ周期 `500 ms` 以下 |
| `注意` | RSSIが `-75 dBm` 未満、または周期が `500 ms` 超 |
| `不安定` | RSSIが `-85 dBm` 未満 |
| `遅延大` | 周期が `1000 ms` 超 |
| `受信中` | データは届いているが基地局APIからRSSIが取得できない |
| `未受信` | 直近3秒間にMAVLink値を受信していない |

## INA780 standalone MAVLink output

`INA780BIDEKR_only_test.ino` は基地局ブリッジと同じ電力フィールドをUSB Serial MAVLinkで送ります。

| Command | Function |
| --- | --- |
| `m` | MAVLinkテレメトリ送信へ切替。起動時の既定モード |
| `a` | 検出したINA780をテキスト形式で連続診断 |
| `1` to `5` | 対象センサをテキスト形式で個別診断 |
| `s` | I2Cスキャンをテキスト表示 |

単体MAVLinkでは `INA_MASK`, `FAULT`, `RSSI=0`, `RX_DT=200`, `LOSS=0` も送信します。VESC CAN値は含まれません。

表示されるINA780値:

```text
BATT_V / BATT_I / BATT_P / BATT_T  主バッテリー
AUX_V  / AUX_I  / AUX_P  / AUX_T   補助供給 (AUX_BATT)
ESC_V  / ESC_I  / ESC_P  / ESC_T   VESC/負荷入力
PV1_V  / PV1_I  / PV1_P  / PV1_T   前方PV
PV2_V  / PV2_I  / PV2_P  / PV2_T   後方PV
INA_MASK  INA780有効チャンネルビットマスク
```

表示される通信およびVESC値:

```text
RSSI      ESP-NOW received RSSI, dBm
RX_DT     receive interval, ms
SEQ       received sequence number
LOSS      estimated lost packet count
FAULT     sender fault flags
CAN_OK    VESC CAN status reception valid (1=valid, 0=stale/error)
CAN_ID    monitored VESC CAN ID
CAN_AGE   age of last VESC status frame in ms
VESC_RPM  VESC electrical RPM
VESC_IMOT VESC motor current
VESC_DUTY VESC duty ratio
VESC_IIN  VESC input current
VESC_VIN  VESC input voltage
VESC_PWR  VESC input electrical power
VESC_TFET VESC FET temperature
VESC_TMOT VESC motor temperature
```

## Outdoor log checks

CSVログで確認する項目:

```text
RSSI
RX_DT
SEQ
LOSS
BATT_P / AUX_P / ESC_P / PV1_P / PV2_P / INA_MASK
CAN_OK / CAN_AGE
VESC_RPM / VESC_VIN / VESC_IIN / VESC_PWR
```

目安:

```text
RX_DT: 200ms前後なら5Hzで正常
LOSS: 増え続けるなら欠落あり
RSSI: 低下や急変がある場所はアンテナ配置を見直す
CAN_OK: 1が維持されなければVESC ID、CAN速度、status送信設定、配線を確認
```

## Next stabilization step

最初はブロードキャスト送信です。通信確認後、基地局XIAOのSTA MACを船体側 `BASE_MAC` に入れて、ユニキャストESP-NOWへ変更すると安定性評価がしやすくなります。
