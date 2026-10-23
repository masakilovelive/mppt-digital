# VC LoRa Bridge 作業ルール

本ファイルは、このディレクトリ以下のホストコア、試験、Arduinoスケッチに適用する。

1. 変更前に、該当する失敗テストを追加する。
2. 一度の変更で、TDDロジックと通信パラメータを同時に変更しない。
3. ホストコアにArduino依存を入れない。
4. 組込みコアでは原則として動的メモリ確保を使用しない。
5. Mission Planner用USB/MAVLink経路へdebug文字列を出さない。
6. 現行ピン割当とUART設定を無断変更しない。
7. 制御フレームはPixhawk/GCSへ漏らさない。
8. テスト成功後に車載・地上のArduinoコンパイルも実行する。
9. 失敗テストを削除または緩和して合格させない。
10. 変更ごとに`summary.json`と差分を保存する。

## 固定ハードウェア条件

- E220: `D0=M0`, `D1=M1`, `D2=XIAO TX -> E220 RXD`,
  `D3=XIAO RX <- E220 TXD`, `D8=AUX`
- Pixhawk: `D6=XIAO TX -> Pixhawk RX`, `D7=XIAO RX <- Pixhawk TX`
- Pixhawk/GCS UART: 57600 bps, 8N1
- E220 UART: 115200 bps, 8N1
- E220プロファイル: `00 00 E5 C3 46 00 00 00`
- chunk 32 byte、partial flush 50 ms（legacy/raw互換）、minimum lower bound 180 ms、
  production effective service floor 550 ms＋AUX HIGH連続15 ms
- TDD controlはcanonical v2 exact32。300 msはwhole-frame admission/start期限であり、
  開始済みtransactionの完了期限ではない。

## 検証コマンド

ホスト試験は`tools/run_host_tests.ps1`を使用する。Arduinoは共有キャッシュの
競合を避けるため、次のFQBNでVehicle、Groundの順にコンパイルする。

```text
esp32:esp32:XIAO_ESP32S3
```

ホストコア`core/`では`Arduino.h`、`HardwareSerial`、`Stream`、`Print`、
`millis`、`micros`、`delay`、GPIO API、`esp_random`を使用しない。
