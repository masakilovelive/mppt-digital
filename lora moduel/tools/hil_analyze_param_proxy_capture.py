#!/usr/bin/env python3
"""Analyze Ground-owned sequential parameter-proxy HIL captures.

The input is one or more binary-safe ``capture.jsonl`` files produced by
``hil_capture_serial.ps1``.  Multiple inputs are concatenated in command-line
order so a long parameter download may be captured in bounded segments.  A
missing footer is retained as explicit evidence instead of making an otherwise
clean, intentionally stopped segment unreadable.

This is a read-only measurement tool.  PASS means the captured stream meets
the checks implemented here; it does not replace firmware-hash, wiring,
Mission Planner completion, or operator evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from hil_analyze_capture import (
    CONTROL_CRC_COVERED_SIZE,
    CONTROL_CRC_OFFSET,
    CONTROL_MAGIC,
    CONTROL_SIZE,
    crc16_ccitt_false,
    load_capture,
    load_definitions,
    parse_mavlink,
)


SCHEMA_VERSION = 1
PARAM_REQUEST_LIST_MESSAGE_ID = 21
PARAM_VALUE_MESSAGE_ID = 22
PARAM_VALUE_PAYLOAD_SIZE = 25
UNLISTED_PARAMETER_INDEX = 0xFFFF
MAX_INDEX_ADDRESSABLE_PARAMETER_COUNT = 0x8000


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def finite_json_float(raw: bytes) -> float | str:
    value = struct.unpack("<f", raw)[0]
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    return value


def decode_param_value(
    frame: dict[str, Any], capture_index: int, ordinal: int
) -> dict[str, Any]:
    payload = bytes.fromhex(frame["payload_hex"])
    if len(payload) != PARAM_VALUE_PAYLOAD_SIZE:
        raise ValueError("validated PARAM_VALUE has an unexpected payload size")
    raw_id = payload[8:24]
    terminator = raw_id.find(b"\0")
    visible_id = raw_id if terminator < 0 else raw_id[:terminator]
    return {
        "ordinal": ordinal,
        "capture_index": capture_index,
        "t_us": int(frame["t_us"]),
        "timestamp_us": int(frame["t_us"]),
        "version": int(frame["version"]),
        "signed": bool(frame["signed"]),
        "sequence": int(frame["sequence"]),
        "system_id": int(frame["system_id"]),
        "component_id": int(frame["component_id"]),
        "index": int.from_bytes(payload[6:8], "little"),
        "count": int.from_bytes(payload[4:6], "little"),
        "id": visible_id.decode("utf-8", errors="replace"),
        "id_raw_hex": raw_id.hex().upper(),
        "id_null_terminated": terminator >= 0,
        "value": finite_json_float(payload[0:4]),
        "value_bits_hex": f"{int.from_bytes(payload[0:4], 'little'):08X}",
        "type": int(payload[24]),
        "crc": int(frame["crc"]),
    }


def decode_param_request_list(
    frame: dict[str, Any], capture_index: int
) -> dict[str, Any]:
    payload = bytes.fromhex(frame["payload_hex"])
    if len(payload) != 2:
        raise ValueError(
            "validated PARAM_REQUEST_LIST has an unexpected payload size"
        )
    return {
        "capture_index": capture_index,
        "t_us": int(frame["t_us"]),
        "timestamp_us": int(frame["t_us"]),
        "version": int(frame["version"]),
        "signed": bool(frame["signed"]),
        "sequence": int(frame["sequence"]),
        "system_id": int(frame["system_id"]),
        "component_id": int(frame["component_id"]),
        "target_system": int(payload[0]),
        "target_component": int(payload[1]),
        "crc": int(frame["crc"]),
    }


def scan_control_candidates(samples: list[tuple[int, int]]) -> dict[str, Any]:
    """Find raw VCTD leakage without assuming a particular protocol version."""
    data = bytes(byte for byte, _ in samples)
    candidates = 0
    crc_valid = 0
    bad_crc = 0
    malformed = 0
    partial = 0
    messages: list[dict[str, Any]] = []
    offset = 0
    while True:
        offset = data.find(CONTROL_MAGIC, offset)
        if offset < 0:
            break
        candidates += 1
        if len(data) - offset < CONTROL_SIZE:
            partial += 1
            break
        frame = data[offset : offset + CONTROL_SIZE]
        if frame[6:8] != b"\x0c\x00":
            malformed += 1
            offset += 1
            continue
        stored_crc = int.from_bytes(
            frame[CONTROL_CRC_OFFSET:CONTROL_SIZE], "little"
        )
        computed_crc = crc16_ccitt_false(
            frame[:CONTROL_CRC_COVERED_SIZE]
        )
        if stored_crc != computed_crc:
            bad_crc += 1
            offset += CONTROL_SIZE
            continue
        crc_valid += 1
        messages.append(
            {
                "t_us": int(samples[offset][1]),
                "offset": offset,
                "version": int(frame[4]),
                "type": int(frame[5]),
                "session_id": int.from_bytes(frame[8:10], "little"),
                "cycle_id": int.from_bytes(frame[10:12], "little"),
                "stored_crc": stored_crc,
            }
        )
        offset += CONTROL_SIZE
    return {
        "magic_candidates": candidates,
        "crc_valid": crc_valid,
        "bad_crc": bad_crc,
        "malformed": malformed,
        "partial": partial,
        "messages": messages,
    }


def direction_without_frames(parsed: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in parsed.items() if key != "frames"}


def capture_end_us(
    streams: dict[str, list[tuple[int, int]]], footer: dict[str, Any] | None
) -> tuple[int, str]:
    if footer is not None and "duration_us" in footer:
        return int(footer["duration_us"]), "footer.duration_us"
    last_sample = max(
        (samples[-1][1] for samples in streams.values() if samples),
        default=0,
    )
    return int(last_sample), "last_sample_t_us"


def heartbeat_summary(
    parsed_captures: list[dict[str, Any]]
) -> dict[str, Any]:
    segments: list[dict[str, Any]] = []
    maximum_gap_us = 0
    maximum_gap: dict[str, Any] | None = None
    total = 0
    first: dict[str, Any] | None = None

    for capture in parsed_captures:
        capture_index = int(capture["index"])
        frames = capture["parsed"]["rx"]["frames"]
        times = [
            int(frame["t_us"])
            for frame in frames
            if frame["message_id"] == 0
        ]
        total += len(times)
        if first is None and times:
            first = {"capture_index": capture_index, "t_us": times[0]}
        segment_maximum_us = 0
        segment_maximum_pair: list[int] | None = None
        for before, after in zip(times, times[1:]):
            gap = after - before
            if gap > segment_maximum_us:
                segment_maximum_us = gap
                segment_maximum_pair = [before, after]
            if gap > maximum_gap_us:
                maximum_gap_us = gap
                maximum_gap = {
                    "capture_index": capture_index,
                    "from_t_us": before,
                    "to_t_us": after,
                    "gap_ms": round(gap / 1000.0, 3),
                }
        end_us = int(capture["end_us"])
        tail_ms = (
            round(max(0, end_us - times[-1]) / 1000.0, 3)
            if times
            else None
        )
        segments.append(
            {
                "capture_index": capture_index,
                "count": len(times),
                "first_t_us": times[0] if times else None,
                "last_t_us": times[-1] if times else None,
                "max_gap_ms": round(segment_maximum_us / 1000.0, 3),
                "max_gap_pair_t_us": segment_maximum_pair,
                "capture_end_t_us": end_us,
                "capture_end_basis": capture["end_basis"],
                "tail_ms": tail_ms,
            }
        )

    final_segment = segments[-1] if segments else None
    return {
        "count": total,
        "first": first,
        "first_t_us": first["t_us"] if first is not None else None,
        "max_gap_ms": round(maximum_gap_us / 1000.0, 3),
        "max_gap": maximum_gap,
        "tail_ms": final_segment["tail_ms"] if final_segment else None,
        "cross_capture_gaps_evaluated": False,
        "segments": segments,
    }


def parameter_download_summary(
    values: list[dict[str, Any]], expected_count: int | None
) -> dict[str, Any]:
    reported_counter = Counter(int(value["count"]) for value in values)
    inferred_count = (
        reported_counter.most_common(1)[0][0] if reported_counter else None
    )
    effective_count = expected_count if expected_count is not None else inferred_count

    indexed = [
        value for value in values
        if int(value["index"]) != UNLISTED_PARAMETER_INDEX
    ]
    sentinel = [
        value for value in values
        if int(value["index"]) == UNLISTED_PARAMETER_INDEX
    ]
    index_counter = Counter(int(value["index"]) for value in indexed)
    duplicates = [
        {"index": index, "occurrences": occurrences,
         "duplicate_frames": occurrences - 1}
        for index, occurrences in sorted(index_counter.items())
        if occurrences > 1
    ]
    duplicate_frame_count = sum(
        item["duplicate_frames"] for item in duplicates
    )

    seen: set[int] = set()
    highest = -1
    out_of_order: list[dict[str, Any]] = []
    for value in indexed:
        index = int(value["index"])
        if index in seen:
            continue
        if index < highest:
            out_of_order.append(
                {
                    "ordinal": int(value["ordinal"]),
                    "capture_index": int(value["capture_index"]),
                    "t_us": int(value["t_us"]),
                    "index": index,
                    "highest_previously_seen": highest,
                }
            )
        seen.add(index)
        highest = max(highest, index)

    missing: list[int] = []
    out_of_range: list[int] = []
    count_mismatch_frame_count = 0
    if effective_count is not None:
        missing = sorted(set(range(effective_count)) - set(index_counter))
        out_of_range = sorted(
            index for index in index_counter if index >= effective_count
        )
        count_mismatch_frame_count = sum(
            occurrences
            for count, occurrences in reported_counter.items()
            if count != effective_count
        )

    complete = bool(
        effective_count is not None and effective_count > 0 and
        len(index_counter) == effective_count and not missing and
        not out_of_range
    )
    coverage_percent = (
        round(100.0 * len(index_counter) / effective_count, 6)
        if effective_count
        else None
    )
    return {
        "expected_count": expected_count,
        "inferred_count": inferred_count,
        "effective_count": effective_count,
        "reported_count_occurrences": {
            str(key): value for key, value in sorted(reported_counter.items())
        },
        "count_mismatch_frame_count": count_mismatch_frame_count,
        "param_value_frame_count": len(values),
        "indexed_frame_count": len(indexed),
        "sentinel_65535_frame_count": len(sentinel),
        "unique_index_count": len(index_counter),
        "coverage_percent": coverage_percent,
        "first_index": int(indexed[0]["index"]) if indexed else None,
        "last_index": int(indexed[-1]["index"]) if indexed else None,
        "duplicate_frame_count": duplicate_frame_count,
        "duplicates": duplicates,
        "missing_count": len(missing),
        "missing_indexes": missing,
        "out_of_range_count": len(out_of_range),
        "out_of_range_indexes": out_of_range,
        "out_of_order_count": len(out_of_order),
        "out_of_order_events": out_of_order,
        "complete": complete,
    }


def analyze(
    capture_paths: list[Path], definitions_path: Path,
    expected_count: int | None = None,
    expected_test_id: str | None = None,
) -> dict[str, Any]:
    if not capture_paths:
        raise ValueError("at least one capture input is required")
    resolved = [path.resolve() for path in capture_paths]
    if len(set(resolved)) != len(resolved):
        raise ValueError("duplicate capture input would duplicate evidence")
    if expected_count is not None and not (
        1 <= expected_count <= MAX_INDEX_ADDRESSABLE_PARAMETER_COUNT
    ):
        raise ValueError("expected_count must be in 1..32768")

    definitions = load_definitions(definitions_path)
    parsed_captures: list[dict[str, Any]] = []
    capture_records: list[dict[str, Any]] = []
    param_values: list[dict[str, Any]] = []
    request_lists: list[dict[str, Any]] = []
    ordinal = 0

    for capture_index, path in enumerate(capture_paths):
        header, streams, footer = load_capture(path, require_footer=False)
        if expected_test_id and header.get("test_id") != expected_test_id:
            raise ValueError(
                f"capture test_id={header.get('test_id')} does not match "
                f"{expected_test_id}"
            )
        end_us, end_basis = capture_end_us(streams, footer)
        parsed = {
            direction: parse_mavlink(
                samples, definitions, include_payload=True
            )
            for direction, samples in streams.items()
        }
        controls = {
            direction: scan_control_candidates(samples)
            for direction, samples in streams.items()
        }
        parsed_captures.append(
            {
                "index": capture_index,
                "parsed": parsed,
                "controls": controls,
                "end_us": end_us,
                "end_basis": end_basis,
            }
        )

        for frame in parsed["rx"]["frames"]:
            if frame["message_id"] == PARAM_VALUE_MESSAGE_ID:
                param_values.append(
                    decode_param_value(frame, capture_index, ordinal)
                )
                ordinal += 1
        for frame in parsed["tx"]["frames"]:
            if frame["message_id"] == PARAM_REQUEST_LIST_MESSAGE_ID:
                request_lists.append(
                    decode_param_request_list(frame, capture_index)
                )

        capture_records.append(
            {
                "index": capture_index,
                "path": str(path.resolve()),
                "sha256": file_sha256(path),
                "test_id": header.get("test_id"),
                "endpoint": header.get("endpoint"),
                "header": header,
                "footer_present": footer is not None,
                "footer": footer,
                "capture_end_t_us": end_us,
                "capture_end_basis": end_basis,
                "directions": {
                    direction: {
                        "mavlink": direction_without_frames(parsed[direction]),
                        "tdd_control_candidates": controls[direction],
                    }
                    for direction in ("rx", "tx")
                },
            }
        )

    integrity = {
        "bad_crc": sum(
            capture["parsed"][direction]["bad_crc"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "partial_bytes": sum(
            capture["parsed"][direction]["partial_bytes"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "noise_bytes": sum(
            capture["parsed"][direction]["noise_bytes"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "bad_payload_length": sum(
            capture["parsed"][direction]["bad_payload_length"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "unsupported_frames": sum(
            capture["parsed"][direction]["unsupported_frames"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "control_magic_candidates": sum(
            capture["controls"][direction]["magic_candidates"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "control_leak_crc_valid": sum(
            capture["controls"][direction]["crc_valid"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "control_bad_crc": sum(
            capture["controls"][direction]["bad_crc"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "control_malformed": sum(
            capture["controls"][direction]["malformed"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
        "control_partial": sum(
            capture["controls"][direction]["partial"]
            for capture in parsed_captures for direction in ("rx", "tx")
        ),
    }
    download = parameter_download_summary(param_values, expected_count)
    heartbeat = heartbeat_summary(parsed_captures)

    integrity_failure = any(
        integrity[key] != 0
        for key in (
            "bad_crc", "partial_bytes", "noise_bytes",
            "bad_payload_length", "control_magic_candidates",
        )
    )
    proxy_sequence_failure = any(
        download[key] != 0
        for key in (
            "count_mismatch_frame_count", "duplicate_frame_count",
            "out_of_range_count", "out_of_order_count",
        )
    )
    if integrity_failure:
        status = "FAIL_INTEGRITY"
    elif proxy_sequence_failure:
        status = "FAIL_PROXY_SEQUENCE"
    elif download["complete"]:
        status = "PASS_COMPLETE"
    elif download["unique_index_count"] > 0:
        status = "PARTIAL_PROGRESS"
    else:
        status = "NO_PROGRESS"

    return {
        "schema_version": SCHEMA_VERSION,
        "analyzer": "hil_analyze_param_proxy_capture.py",
        "status": status,
        "measurement_only": True,
        "mavlink_crc_revalidated": True,
        "mavlink2_signature_cryptographically_verified": False,
        "capture_order_is_command_line_order": True,
        "definitions": str(definitions_path.resolve()),
        "definitions_sha256": file_sha256(definitions_path),
        "captures": capture_records,
        "integrity": integrity,
        "tx_param_request_list": {
            "count": len(request_lists),
            "frames": request_lists,
        },
        "parameter_download": download,
        "heartbeat": heartbeat,
        "param_values": param_values,
    }


def expected_count_argument(raw: str) -> int:
    value = int(raw)
    if not 1 <= value <= MAX_INDEX_ADDRESSABLE_PARAMETER_COUNT:
        raise argparse.ArgumentTypeError("must be in 1..32768")
    return value


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input", action="append", required=True, type=Path,
        help="capture.jsonl; repeat in chronological segment order",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-count", type=expected_count_argument)
    parser.add_argument(
        "--test-id", help="require every input header to have this test_id"
    )
    parser.add_argument(
        "--definitions", type=Path,
        default=(Path(__file__).resolve().parents[1] / "core" / "src"
                 / "mavlink_frame.cpp"),
        help="authoritative MAVLink definition source",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite evidence: {args.output}")
    result = analyze(
        args.input, args.definitions, args.expected_count, args.test_id
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            result, indent=2, ensure_ascii=False, allow_nan=False
        ) + "\n",
        encoding="utf-8",
    )
    print(
        f"{result['status']} captures={len(result['captures'])} "
        f"unique={result['parameter_download']['unique_index_count']} "
        f"output={args.output}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
