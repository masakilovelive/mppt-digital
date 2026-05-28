# Pixhawk 6C + XIAO ESP32-S3 UART MAVLink Test

Pixhawk 6C の TELEM1 と XIAO ESP32-S3 の UART を直結し、MAVLink が読めるかを確認する最小テストです。

## 目的

1. Pixhawk 6C から XIAO へ `HEARTBEAT` が届くことを確認する。
2. XIAO から Pixhawk へ `MAV_CMD_SET_MESSAGE_INTERVAL` を送り、`ATTITUDE` / `GPS_RAW_INT` / `SYS_STATUS` / `BATTERY_STATUS` が返ることを確認する。
3. Mission Planner は Pixhawk の USB-C 接続のまま使い、TELEM1 は XIAO 専用にする。

## 配線

初回は XIAO を USB でPCから給電し、Pixhawk 5V は接続しない方が安全です。必ず GND は共通にします。

```text
Pixhawk 6C TELEM1 TX  ->  XIAO ESP32-S3 D7/RX/GPIO44
Pixhawk 6C TELEM1 RX  <-  XIAO ESP32-S3 D6/TX/GPIO43
Pixhawk 6C GND        <-> XIAO ESP32-S3 GND
Pixhawk 6C 5V         ->  未接続から開始
CTS / RTS             ->  未接続
```

スケッチ内のUARTピンは `GPIO44` / `GPIO43` を直指定している。ESP32 Arduinoの `HardwareSerial.begin()` はGPIO番号を受け取るため、`D6` / `D7` マクロは使わない。

TELEM 6pin JST-GH の一般的な並び:

| Pin | Signal |
|---:|---|
| 1 | 5V |
| 2 | TX |
| 3 | RX |
| 4 | CTS |
| 5 | RTS |
| 6 | GND |

## Pixhawk / ArduPilot 設定

Mission Planner を Pixhawk USB-C で接続し、`Config/Tuning > Full Parameter Tree` で TELEM1 を設定します。

```text
SERIAL1_PROTOCOL = 2    # MAVLink2
SERIAL1_BAUD     = 115  # 115200 bps
BRD_SER1_RTSCTS  = 0    # flow control disabled
```

TELEM2 を使う場合は `SERIAL2_*` に読み替えます。

設定後、Pixhawk を再起動します。

## Arduino IDE 設定

- Board: `XIAO_ESP32S3` または `ESP32S3 Dev Module`
- USB CDC On Boot: `Enabled`
- Upload Speed: 任意
- Serial Monitor baud: `115200`

書き込むファイル:

```text
pixhawk6c_xiao_esp32s3_uart_mavlink_test.ino
```

## 確認手順

1. Pixhawk を USB-C でPCへ接続し、Mission Plannerで上記パラメータを設定する。
2. XIAO ESP32-S3 へスケッチを書き込む。
3. Pixhawk TELEM1 と XIAO を `TX/RXクロス + GND共通` で接続する。
4. Arduino Serial Monitor を `115200` で開く。
5. 次のような表示を確認する。

```text
[OK] HEARTBEAT from Pixhawk/ArduPilot sys=1 comp=1 mav=v2
[TX] First Pixhawk heartbeat seen. Requesting telemetry streams...
[RX] COMMAND_ACK command=511 result=0
[STAT] raw=... stx=... frames=... hb=... att=... gps=... sys=... bat=... unk=... crc_bad=0 baud=115200 | last_id=...
```

成功判定:

| 確認項目 | 意味 |
|---|---|
| `HEARTBEAT` が増える | Pixhawk TX -> XIAO RX がOK |
| `COMMAND_ACK command=511 result=0` が出る | XIAO TX -> Pixhawk RX がOK |
| `att` / `gps` / `sys` が増える | PixhawkがXIAOからの要求に応答している |
| `crc_bad=0` 付近 | baud / 配線 / ノイズが正常 |

## 今回確認できた成功状態

以下が表示されれば、Pixhawk 6C と XIAO ESP32-S3 のUART/MAVLink双方向通信は成功です。

```text
[RX] COMMAND_ACK command=511 result=0
[STAT] ... hb=...(+1) att=... sys=... bat=... ack=...
```

意味:

| 表示 | 判定 |
|---|---|
| `hb=...(+1)` | Pixhawk -> XIAO のHEARTBEAT受信OK |
| `att` / `sys` / `bat` が増える | Pixhawk telemetry stream受信OK |
| `COMMAND_ACK command=511 result=0` | XIAO -> Pixhawk のコマンド送信OK |
| `ack` が増える | PixhawkがXIAO送信コマンドに応答している |
| `crc_bad` が増え続けない | baudと信号品質は実用範囲 |

`unk_id` が出ても、`crc_bad` が増え続けなければ通信エラーとは限らない。これはテストスケッチが全MAVLink/ArduPilot固有メッセージを解釈していないため。

## Serial Monitor コマンド

| Command | Action |
|---|---|
| `r` | telemetry stream request を再送する |
| `t` | `STATUSTEXT` をPixhawk側へ送る |
| `b` | Pixhawk UART baudを `57600 -> 115200 -> 230400 -> 460800 -> 921600` の順で切り替える |
| `c` | カウンタをクリアする |
| `h` | ヘルプ表示 |

## うまくいかない場合

| 症状 | 確認 |
|---|---|
| `raw=0` / `no_raw` のまま | Pixhawk TELEM TX と XIAO RX が逆でないか、GND共通か、Pixhawk側のTELEM設定が有効か |
| `raw` は増えるが `hb=0` | Pixhawk側baudまたはprotocol不一致の可能性が高い。Serial Monitorから `b` を送ってbaudを切り替える |
| `raw` と `frames` は大量に増えるが `last_id` のsys/compが不自然 | UART RXピン違い、浮いた入力ノイズ、またはbaud不一致。まずGPIO44/43指定版を書き込み直し、D6-D7ループバックを確認 |
| `raw` は増えるが `frames=0` | `SERIAL1_BAUD` とスケッチのbaudが一致しているか。まず両方 `115200` にする |
| `stx` は増えるが `crc_bad` が増える | baud不一致、MAVLink CRC定義外メッセージ、ノイズ、GND不良 |
| `HEARTBEAT` は出るが `COMMAND_ACK` がない | XIAO TX -> Pixhawk RX 配線、`SERIAL1_PROTOCOL`、`BRD_SER1_RTSCTS=0` |
| `crc_bad` が増える | baud不一致、GND不良、長すぎる配線、TX/RX接触不良 |
| Mission PlannerがTELEMを使っている | Mission PlannerはPixhawk USB-Cへ接続する |

## `raw=0` の切り分け

`raw=0` は、XIAOのRXピンに1バイトも届いていない状態です。次の順で確認します。

### 1. XIAO単体のUARTループバック

Pixhawkを一度外し、XIAOの以下をジャンパ線で直結します。

```text
XIAO D6/TX/GPIO43 -> XIAO D7/RX/GPIO44
```

このスケッチは1秒ごとにUARTへGCS heartbeatを送っているため、ループバックが正しければSerial Monitorで `raw` と `frames` が増えます。

```text
[STAT] raw=... stx=... frames=... hb=... | ...
```

結果の見方:

| 結果 | 意味 |
|---|---|
| ループバックで `raw` が増える | XIAOのD6/D7 UARTは正常。Pixhawk側出力またはTELEM配線を確認 |
| ループバックでも `raw=0` | XIAOのピン番号、ボード設定、ジャンパ位置を確認 |

### 2. Pixhawk TELEM1の出力確認

ループバックが正常なら、Pixhawk側を確認します。

```text
SERIAL1_PROTOCOL = 2
SERIAL1_BAUD     = 115
BRD_SER1_RTSCTS  = 0
```

設定後はPixhawkを再起動します。TELEM2を使う場合は `SERIAL2_*` と `BRD_SER2_RTSCTS` に読み替えます。

### 3. JST-GHコネクタの向き確認

TELEMピン番号はコネクタの見た目だけで判断しないでください。最初にテスターでPin 1の5VとPin 6のGNDを確認してから、Pin 2 TX と Pin 3 RX を決めます。

## メモ

このテストは制御指令を出しません。送信するのは GCS heartbeat、メッセージ周期要求、STATUSTEXT のみです。
