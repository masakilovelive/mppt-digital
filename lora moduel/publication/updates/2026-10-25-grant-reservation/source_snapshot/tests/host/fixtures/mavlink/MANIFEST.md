# MAVLink golden fixture manifest

- Generator: Mission Planner 1.3.83 build 1.3.9384.38258
- MAVLink.dll product version:
  `1.0.7+b78a7495fec69793f2fcc13be4b6a3d9e06b3e4e`
- MAVLink.dll SHA-256:
  `122552511CFCA19931F64CCBC148499D7073C295FF3480637132AB664A8969D6`
- Dialect: `ardupilotmega`
- Storage: fixed binary byte arrays in `golden_frames.hpp`, linked directly
  into the offline CTest executable
- CRC algorithm: MAVLink X.25 plus `CRC_EXTRA`; checksum bytes are stored
  little-endian on the wire

| Fixture | v | sys/comp | seq | msgid | payload | CRC extra | CRC |
|---|---:|---:|---:|---:|---:|---:|---:|
| Pixhawk HEARTBEAT | 2 | 1/1 | 0 | 0 | 9 | 50 | `B629` |
| GCS HEARTBEAT | 1 | 255/190 | 0 | 0 | 9 | 50 | `2149` |
| PARAM_REQUEST_READ | 2 | 255/190 | 1 | 20 | 20 | 214 | `F698` |
| PARAM_VALUE | 2 | 1/1 | 1 | 22 | 25 | 220 | `876A` |
| PARAM_SET | 1 | 255/190 | 2 | 23 | 23 | 168 | `50F6` |
| PARAM_VALUE | 1 | 1/1 | 2 | 22 | 25 | 220 | `E83C` |
| COMMAND_LONG | 2 | 255/190 | 3 | 76 | 33 | 152 | `CF6F` |
| COMMAND_ACK full extensions | 2 | 1/1 | 3 | 77 | 10 | 143 | `A6A4` |
| PID_TUNING | 2 | 1/1 | 4 | 194 | 25 | 98 | `739D` |

The Mission Planner-equivalent burst is 17 unsigned MAVLink 2 `PARAM_SET`
frames, 35 bytes each, sequences 40 through 56, parameter IDs
`TEST_PARAM_00` through `TEST_PARAM_16`, and values 0 through 16. Expected
CRCs are `E914 521A 1379 3A7A D21F 7422 9674 3049 5C66 BDC4 21E8 C04A
64AA 8508 BF53 5EF1 EE2E`. The concatenated 595-byte SHA-256 is
`3A378EDAA8F36C650B31A46C41DDBF079DCBF97E3526F13C1C0FCD9E773D8674`.

## Live Pixhawk PARAM_ERROR fixture

`kPixhawkParamErrorV2` is the exact 33-byte response captured from Pixhawk
COM26 at `t_us=1117018` in
`runs/hil/E2E-MAV-PARAM-READ-DIRECT-001/20260818T140046Z-pixhawk-com26/capture.jsonl`.
It is MAVLink 2 message 345 with a 21-byte payload, sequence 10, source 1/1,
parameter ID `ARMING_CHECK`, error 1 (`DOES_NOT_EXIST`), and wire checksum
`0C03`. Brute-forcing the 256 possible CRC-extra bytes against those fixed
wire bytes produces the single match 209. The current MAVLink `common.xml`
field layout is `int16 + uint8 + uint8 + char[16] + uint8`, exactly 21 bytes,
with no extension fields, so minimum and maximum payload lengths are both 21.

The installed Mission Planner 1.3.83 DLL predates message 345. This one
allow-list entry therefore uses the captured Pixhawk response plus the current
upstream `common.xml`, instead of claiming provenance from that older DLL.

## Phase 6 message-definition source

`FW-MAV-001` and `FW-MAV-002` use literal `msgid`, `crc`, `minlength`, and
`length` values reflected from the `MAVLINK_MESSAGE_INFOS` field of the exact
local `MAVLink.dll` identified by the SHA-256 above.  The selected explicit
allow-list covers connection/parameter/command/mission messages and the
representative Pixhawk telemetry/status set. Message 345 uses the separately
documented evidence above. `mavlink_frame.cpp` contains the same fixed table;
IDs absent from that table remain unsupported rather than falling back to an
unchecked CRC-extra value.
