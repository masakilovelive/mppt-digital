#!/usr/bin/env python3
"""Analyze binary-safe VC LoRa HIL serial captures.

This tool deliberately reports measurements, not a HIL PASS.  The operator
must combine both endpoints, logic-analyzer AUX evidence, firmware hashes, and
the criteria in HIL_TEST_PLAN.md before signing a test result.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
CONTROL_MAGIC = b"VCTD"
CONTROL_VERSION = 2
CONTROL_FIELDS_SIZE = 20
CONTROL_RESERVED_OFFSET = CONTROL_FIELDS_SIZE
CONTROL_RESERVED_SIZE = 10
CONTROL_CRC_OFFSET = CONTROL_RESERVED_OFFSET + CONTROL_RESERVED_SIZE
CONTROL_CRC_COVERED_SIZE = CONTROL_CRC_OFFSET
CONTROL_SIZE = CONTROL_CRC_OFFSET + 2
CONTROL_TYPES = {1: "UL_GRANT", 2: "UL_DONE", 3: "UL_IDLE", 4: "LINK_STATUS"}

assert CONTROL_SIZE == 32


def x25_accumulate(crc: int, byte: int) -> int:
    mixed = byte ^ (crc & 0xFF)
    mixed ^= (mixed << 4) & 0xFF
    return (
        (crc >> 8) ^ (mixed << 8) ^ (mixed << 3) ^ (mixed >> 4)
    ) & 0xFFFF


def x25_crc(data: bytes, extra: int) -> int:
    crc = 0xFFFF
    for byte in data:
        crc = x25_accumulate(crc, byte)
    return x25_accumulate(crc, extra)


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def load_definitions(source: Path) -> dict[int, tuple[int, int, int]]:
    text = source.read_text(encoding="utf-8")
    pattern = re.compile(
        r"\{\s*(\d+)U\s*,\s*(\d+)U\s*,\s*(\d+)U\s*,\s*(\d+)U\s*\}"
    )
    definitions: dict[int, tuple[int, int, int]] = {}
    for match in pattern.finditer(text):
        msgid, extra, minimum, maximum = (int(value) for value in match.groups())
        definitions[msgid] = (extra, minimum, maximum)
    if 0 not in definitions or definitions[0] != (50, 9, 9):
        raise ValueError(f"MAVLink definitions not found in {source}")
    return definitions


def load_capture(
    path: Path, *, require_footer: bool = True
) -> tuple[
    dict[str, Any], dict[str, list[tuple[int, int]]], dict[str, Any] | None
]:
    header: dict[str, Any] | None = None
    footer: dict[str, Any] | None = None
    streams: dict[str, list[tuple[int, int]]] = {"rx": [], "tx": []}
    last_time = {"rx": -1, "tx": -1}

    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, 1):
            if not raw_line.strip():
                continue
            record = json.loads(raw_line)
            kind = record.get("kind")
            if kind == "header":
                if header is not None:
                    raise ValueError(f"duplicate capture header at line {line_number}")
                if record.get("schema_version") != SCHEMA_VERSION:
                    raise ValueError("unsupported capture schema")
                header = record
            elif kind == "footer":
                footer = record
            elif kind == "bytes":
                direction = record.get("direction")
                if direction not in streams:
                    raise ValueError(f"invalid direction at line {line_number}")
                timestamp = int(record["t_us"])
                if timestamp < last_time[direction]:
                    raise ValueError(
                        f"non-monotonic {direction} timestamp at line {line_number}"
                    )
                last_time[direction] = timestamp
                payload = base64.b64decode(record["data_b64"], validate=True)
                streams[direction].extend((byte, timestamp) for byte in payload)
            else:
                raise ValueError(f"unknown record kind at line {line_number}: {kind}")

    if header is None:
        raise ValueError("capture header is missing")
    if footer is None and require_footer:
        raise ValueError("capture footer is missing")
    return header, streams, footer


def parse_controls(samples: list[tuple[int, int]]) -> dict[str, Any]:
    data = bytes(byte for byte, _ in samples)
    controls: list[dict[str, Any]] = []
    bad_crc = 0
    malformed = 0
    nonzero_reserved_padding = 0
    unknown_version = 0
    unknown_type = 0
    index = 0
    while True:
        index = data.find(CONTROL_MAGIC, index)
        if index < 0:
            break
        if len(data) - index < CONTROL_SIZE:
            malformed += 1
            break
        frame = data[index : index + CONTROL_SIZE]
        if frame[6:8] != b"\x0c\x00":
            malformed += 1
            index += CONTROL_SIZE
            continue
        expected_crc = int.from_bytes(
            frame[CONTROL_CRC_OFFSET:CONTROL_SIZE], "little"
        )
        if (
            crc16_ccitt_false(frame[:CONTROL_CRC_COVERED_SIZE])
            != expected_crc
        ):
            bad_crc += 1
            index += CONTROL_SIZE
            continue
        if frame[
            CONTROL_RESERVED_OFFSET:CONTROL_CRC_OFFSET
        ] != bytes(CONTROL_RESERVED_SIZE):
            nonzero_reserved_padding += 1
            malformed += 1
            index += CONTROL_SIZE
            continue
        if frame[4] != CONTROL_VERSION:
            unknown_version += 1
            malformed += 1
            index += CONTROL_SIZE
            continue
        if frame[5] not in CONTROL_TYPES:
            unknown_type += 1
            malformed += 1
            index += CONTROL_SIZE
            continue
        controls.append(
            {
                "t_us": samples[index][1],
                "version": frame[4],
                "type": CONTROL_TYPES[frame[5]],
                "session_id": int.from_bytes(frame[8:10], "little"),
                "cycle_id": int.from_bytes(frame[10:12], "little"),
                "guard_ms": int.from_bytes(frame[12:14], "little"),
                "window_ms": int.from_bytes(frame[14:16], "little"),
                "max_bytes": int.from_bytes(frame[16:18], "little"),
                "actual_bytes": int.from_bytes(frame[18:20], "little"),
            }
        )
        index += CONTROL_SIZE

    sessions: list[int] = []
    for control in controls:
        session = int(control["session_id"])
        if not sessions or sessions[-1] != session:
            sessions.append(session)
    return {
        "valid": len(controls),
        "bad_crc": bad_crc,
        "malformed": malformed,
        "nonzero_reserved_padding": nonzero_reserved_padding,
        "unknown_version": unknown_version,
        "unknown_type": unknown_type,
        "type_counts": dict(Counter(control["type"] for control in controls)),
        "session_sequence": sessions,
        "all_sessions_nonzero": all(session != 0 for session in sessions),
        "messages": controls,
    }


def parse_mavlink(
    samples: list[tuple[int, int]],
    definitions: dict[int, tuple[int, int, int]],
    *,
    include_payload: bool = False,
) -> dict[str, Any]:
    data = bytes(byte for byte, _ in samples)
    valid_frames: list[dict[str, Any]] = []
    valid_wire = bytearray()
    noise = 0
    bad_crc = 0
    unsupported = 0
    bad_payload_length = 0
    partial_bytes = 0
    index = 0

    def abandon_or_finish_incomplete(candidate_index: int) -> bool:
        """Return True only when no later sync byte can be examined."""
        nonlocal index, partial_bytes, noise
        later_v1 = data.find(b"\xFE", candidate_index + 1)
        later_v2 = data.find(b"\xFD", candidate_index + 1)
        later = [value for value in (later_v1, later_v2) if value >= 0]
        if later:
            noise += 1
            index += 1
            return False
        partial_bytes = len(data) - candidate_index
        return True

    while index < len(data):
        magic = data[index]
        if magic not in (0xFE, 0xFD):
            noise += 1
            index += 1
            continue
        if len(data) - index < 2:
            if abandon_or_finish_incomplete(index):
                break
            continue
        payload_length = data[index + 1]
        if magic == 0xFE:
            header_size = 6
            if len(data) - index < header_size:
                if abandon_or_finish_incomplete(index):
                    break
                continue
            frame_size = payload_length + 8
            msgid = data[index + 5]
            sequence, system_id, component_id = data[index + 2 : index + 5]
            checksum_offset = 6 + payload_length
            crc_input_end = checksum_offset
            signed = False
            version = 1
        else:
            header_size = 10
            if len(data) - index < header_size:
                if abandon_or_finish_incomplete(index):
                    break
                continue
            incompatibility_flags = data[index + 2]
            signed = bool(incompatibility_flags & 0x01)
            frame_size = payload_length + 12 + (13 if signed else 0)
            msgid = (
                data[index + 7]
                | (data[index + 8] << 8)
                | (data[index + 9] << 16)
            )
            sequence, system_id, component_id = data[index + 4 : index + 7]
            checksum_offset = 10 + payload_length
            crc_input_end = checksum_offset
            version = 2

        if len(data) - index < frame_size:
            if abandon_or_finish_incomplete(index):
                break
            continue
        frame = data[index : index + frame_size]
        definition = definitions.get(msgid)
        if definition is None:
            unsupported += 1
            index += frame_size
            continue
        extra, minimum, maximum = definition
        if payload_length < minimum or payload_length > maximum:
            bad_payload_length += 1
            index += 1
            continue
        stored_crc = int.from_bytes(
            data[index + checksum_offset : index + checksum_offset + 2], "little"
        )
        calculated_crc = x25_crc(data[index + 1 : index + crc_input_end], extra)
        if calculated_crc != stored_crc:
            bad_crc += 1
            index += 1
            continue
        valid_wire.extend(frame)
        frame_record = {
            "t_us": samples[index][1],
            "version": version,
            "signed": signed,
            "size": frame_size,
            "payload_length": payload_length,
            "sequence": sequence,
            "system_id": system_id,
            "component_id": component_id,
            "message_id": msgid,
            "crc": stored_crc,
        }
        if include_payload:
            frame_record["payload_hex"] = frame[
                header_size : header_size + payload_length
            ].hex().upper()
        valid_frames.append(frame_record)
        index += frame_size

    heartbeat_times = [
        frame["t_us"] for frame in valid_frames if frame["message_id"] == 0
    ]
    gaps = [
        heartbeat_times[i] - heartbeat_times[i - 1]
        for i in range(1, len(heartbeat_times))
    ]
    return {
        "stream_bytes": len(data),
        "stream_sha256": hashlib.sha256(data).hexdigest().upper(),
        "valid_frame_bytes": len(valid_wire),
        "valid_frame_sha256": hashlib.sha256(valid_wire).hexdigest().upper(),
        "valid_frames": len(valid_frames),
        "bad_crc": bad_crc,
        "unsupported_frames": unsupported,
        "bad_payload_length": bad_payload_length,
        "noise_bytes": noise,
        "partial_bytes": partial_bytes,
        "signed_frames": sum(1 for frame in valid_frames if frame["signed"]),
        "message_counts": {
            str(key): value
            for key, value in sorted(
                Counter(frame["message_id"] for frame in valid_frames).items()
            )
        },
        "source_counts": {
            key: value
            for key, value in sorted(
                Counter(
                    f"{frame['system_id']}/{frame['component_id']}"
                    for frame in valid_frames
                ).items()
            )
        },
        "heartbeat": {
            "count": len(heartbeat_times),
            "first_t_us": heartbeat_times[0] if heartbeat_times else None,
            "last_t_us": heartbeat_times[-1] if heartbeat_times else None,
            "max_gap_ms": max(gaps) / 1000.0 if gaps else 0.0,
        },
        "frames": valid_frames,
    }


def analyze(
    capture_path: Path, definitions_path: Path, expected_test_id: str | None
) -> dict[str, Any]:
    header, streams, footer = load_capture(capture_path)
    if expected_test_id and header.get("test_id") != expected_test_id:
        raise ValueError(
            f"capture test_id={header.get('test_id')} does not match {expected_test_id}"
        )
    definitions = load_definitions(definitions_path)
    direction_results = {}
    for direction, samples in streams.items():
        direction_results[direction] = {
            "mavlink": parse_mavlink(samples, definitions),
            "tdd_control": parse_controls(samples),
        }
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ANALYZED_NOT_YET_JUDGED",
        "measurement_only": True,
        "test_id": header.get("test_id"),
        "endpoint": header.get("endpoint"),
        "capture": str(capture_path.resolve()),
        "capture_sha256": hashlib.sha256(capture_path.read_bytes())
        .hexdigest()
        .upper(),
        "definitions": str(definitions_path.resolve()),
        "definitions_sha256": hashlib.sha256(definitions_path.read_bytes())
        .hexdigest()
        .upper(),
        "capture_header": header,
        "capture_footer": footer,
        "directions": direction_results,
    }


def make_control(session: int, cycle: int) -> bytes:
    frame = bytearray(b"VCTD\x02\x01\x0c\x00")
    for value in (session, cycle, 650, 300, 64, 0):
        frame.extend(int(value).to_bytes(2, "little"))
    frame.extend(bytes(CONTROL_RESERVED_SIZE))
    assert len(frame) == CONTROL_CRC_OFFSET
    frame.extend(
        crc16_ccitt_false(frame[:CONTROL_CRC_COVERED_SIZE]).to_bytes(
            2, "little"
        )
    )
    assert len(frame) == CONTROL_SIZE
    return bytes(frame)


def run_self_test(definitions_path: Path) -> None:
    production_definitions = load_definitions(definitions_path)
    assert len(production_definitions) >= 67
    assert production_definitions[194] == (98, 25, 33)
    heartbeat = bytes(
        [
            0xFD,
            0x09,
            0x00,
            0x00,
            0x00,
            0x01,
            0x01,
            0x00,
            0x00,
            0x00,
            0x44,
            0x33,
            0x22,
            0x11,
            0x02,
            0x03,
            0x51,
            0x04,
            0x03,
            0x29,
            0xB6,
        ]
    )
    control = make_control(0x1234, 0xFFFE)
    assert len(control) == 32
    assert control[:8] == b"VCTD\x02\x01\x0c\x00"
    assert control[CONTROL_RESERVED_OFFSET:CONTROL_CRC_OFFSET] == bytes(
        CONTROL_RESERVED_SIZE
    )
    assert int.from_bytes(control[CONTROL_CRC_OFFSET:CONTROL_SIZE], "little") == (
        crc16_ccitt_false(control[:CONTROL_CRC_COVERED_SIZE])
    )

    stream = heartbeat + control + heartbeat
    samples = []
    for index, byte in enumerate(stream):
        timestamp = 0 if index < len(heartbeat) else 1_000_000
        samples.append((byte, timestamp))
    mavlink = parse_mavlink(samples, {0: (50, 9, 9)})
    controls = parse_controls(samples)
    assert mavlink["valid_frames"] == 2
    assert mavlink["heartbeat"]["count"] == 2
    assert mavlink["heartbeat"]["max_gap_ms"] == 1000.0
    assert controls["valid"] == 1
    assert controls["session_sequence"] == [0x1234]
    assert controls["messages"][0]["version"] == CONTROL_VERSION

    # Two exact control frames are consumed independently with no padding
    # leaked into the next candidate.
    adjacent_controls = parse_controls(
        [(byte, index) for index, byte in enumerate(control + control)]
    )
    assert adjacent_controls["valid"] == 2
    assert adjacent_controls["bad_crc"] == 0
    assert adjacent_controls["malformed"] == 0

    # Reserved bytes are covered by the CRC. A wire bit error is BadCrc;
    # recomputing a valid CRC over non-zero padding remains structurally
    # malformed under the v2 contract.
    bad_padding_crc = bytearray(control)
    bad_padding_crc[CONTROL_RESERVED_OFFSET] = 1
    padding_crc_result = parse_controls(
        [(byte, index) for index, byte in enumerate(bad_padding_crc)]
    )
    assert padding_crc_result["valid"] == 0
    assert padding_crc_result["bad_crc"] == 1
    bad_then_valid = parse_controls(
        [
            (byte, index)
            for index, byte in enumerate(bytes(bad_padding_crc) + control)
        ]
    )
    assert bad_then_valid["bad_crc"] == 1
    assert bad_then_valid["valid"] == 1

    nonzero_padding = bytearray(bad_padding_crc)
    nonzero_padding[CONTROL_CRC_OFFSET:CONTROL_SIZE] = crc16_ccitt_false(
        nonzero_padding[:CONTROL_CRC_COVERED_SIZE]
    ).to_bytes(2, "little")
    padding_result = parse_controls(
        [(byte, index) for index, byte in enumerate(nonzero_padding)]
    )
    assert padding_result["valid"] == 0
    assert padding_result["malformed"] == 1
    assert padding_result["nonzero_reserved_padding"] == 1

    legacy_version = bytearray(control)
    legacy_version[4] = 1
    legacy_version[CONTROL_CRC_OFFSET:CONTROL_SIZE] = crc16_ccitt_false(
        legacy_version[:CONTROL_CRC_COVERED_SIZE]
    ).to_bytes(2, "little")
    legacy_result = parse_controls(
        [(byte, index) for index, byte in enumerate(legacy_version)]
    )
    assert legacy_result["valid"] == 0
    assert legacy_result["unknown_version"] == 1

    invalid_type = bytearray(control)
    invalid_type[5] = 0xFF
    invalid_type[CONTROL_CRC_OFFSET:CONTROL_SIZE] = crc16_ccitt_false(
        invalid_type[:CONTROL_CRC_COVERED_SIZE]
    ).to_bytes(2, "little")
    type_result = parse_controls(
        [(byte, index) for index, byte in enumerate(invalid_type)]
    )
    assert type_result["valid"] == 0
    assert type_result["unknown_type"] == 1

    truncated_result = parse_controls(
        [(byte, index) for index, byte in enumerate(control[:-1])]
    )
    assert truncated_result["valid"] == 0
    assert truncated_result["malformed"] == 1

    # Escaped application data begins with 0x7d,0x76 rather than raw 'V';
    # the control scanner must not reinterpret it. MAVLink parsing remains an
    # independent raw-stream operation and still resynchronizes around noise.
    escaped_application = b"\x7d\x76" + control[1:]
    escaped_controls = parse_controls(
        [(byte, index) for index, byte in enumerate(escaped_application)]
    )
    assert escaped_controls["valid"] == 0
    raw_with_escape = heartbeat + b"\x7d\x76" + heartbeat
    escaped_mavlink = parse_mavlink(
        [(byte, index) for index, byte in enumerate(raw_with_escape)],
        {0: (50, 9, 9)},
    )
    assert escaped_mavlink["valid_frames"] == 2
    assert escaped_mavlink["heartbeat"]["count"] == 2

    with tempfile.TemporaryDirectory() as temporary:
        capture = Path(temporary) / "capture.jsonl"
        records = [
            {
                "kind": "header",
                "schema_version": 1,
                "test_id": "E2E-MAV-001",
                "endpoint": "ground_usb",
            },
            {
                "kind": "bytes",
                "t_us": 0,
                "direction": "rx",
                "data_b64": base64.b64encode(stream).decode("ascii"),
            },
            {"kind": "footer", "completed": True},
        ]
        capture.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )
        header, loaded, footer = load_capture(capture)
        assert header["test_id"] == "E2E-MAV-001"
        assert footer["completed"] is True
        assert len(loaded["rx"]) == len(stream)
    print("SELFTEST PASS hil_analyze_capture.py")


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="capture.jsonl from hil_capture_serial.ps1")
    parser.add_argument("--output", type=Path, help="measurement summary JSON")
    parser.add_argument("--test-id", help="reject a capture tagged with a different test ID")
    parser.add_argument(
        "--definitions",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "core" / "src" / "mavlink_frame.cpp",
        help="authoritative MAVLink definition source",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(list(argv))
    if not args.self_test and (args.input is None or args.output is None):
        parser.error("--input and --output are required unless --self-test is used")
    return args


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test(args.definitions)
        return 0
    result = analyze(args.input, args.definitions, args.test_id)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite evidence: {args.output}")
    args.output.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        f"ANALYZED_NOT_YET_JUDGED {result['test_id']} "
        f"endpoint={result['endpoint']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
