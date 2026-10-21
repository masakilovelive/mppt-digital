#!/usr/bin/env python3
"""Extract a deterministic 932-frame replay fixture from accepted R18 evidence.

The output wire stream contains the exact unsigned MAVLink 2 PARAM_VALUE
frames accepted by Mission Planner in R18.  Timestamps and all interleaved
messages are removed; frame headers, payloads, source sequence numbers and
CRC bytes are preserved byte-for-byte.  This is an offline evidence tool: it
does not enumerate, open, or write a serial port and does not invoke esptool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TLOG = (
    ROOT / "runs" / "hil"
    / "R18-MISSION-PLANNER-PRODUCTION-001"
    / "20260914T134437Z" / "mission_planner.tlog"
)
DEFAULT_ACCEPTANCE_SUMMARY = (
    ROOT / "runs" / "baselines" / "R18-PRODUCTION-R4-ACCEPTED"
    / "20260914T225054625Z" / "artifacts" / "summary.json"
)
ANALYZER = ROOT / "tools" / "analyze_mission_planner_tlog.py"
DEFINITIONS = ROOT / "core" / "src" / "mavlink_frame.cpp"

EXPECTED_COUNT = 932
FRAME_SIZE = 37
PARAM_VALUE_MESSAGE_ID = 22
PARAM_VALUE_CRC_EXTRA = 220
EXPECTED_SOURCE = (1, 1)
EXPECTED_TLOG_SHA256 = (
    "E0EE29BBA1DBA09381A8FACAFCE299860A3E2C3FB7A6970A3EAF7C304DDA712D"
)
EXPECTED_ACCEPTANCE_SUMMARY_SHA256 = (
    "09E748985E1A745BD2B87A25C7A3F5DBA3827D52DE644F7F7CE9BE107936D6E7"
)
EXPECTED_ANALYZER_SHA256 = (
    "AFAA9BD23B0A9B128E6CBDA2F97C8587A64D0ED449B0819E01E387A4F660DED9"
)
EXPECTED_DEFINITIONS_SHA256 = (
    "BD2890D8973C5A694D53AB2866A6B3DBF319FAE40B3CC308AE2DAE91B634F3A8"
)

STREAM_NAME = "param_value_932.mavlink.bin"
INDEX_NAME = "param_value_932.index.jsonl"
VALIDATION_NAME = "validation.json"
MANIFEST_NAME = "manifest.json"
CHECKSUMS_NAME = "SHA256SUMS.txt"


class FixtureError(RuntimeError):
    """Raised when source provenance or fixture integrity is not exact."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def repo_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return str(resolved)


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


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


def decode_param_id(raw: bytes) -> str:
    saw_zero = False
    visible = 0
    for value in raw:
        if value == 0:
            saw_zero = True
        elif saw_zero or value < 0x20 or value > 0x7E:
            raise FixtureError(
                f"invalid PARAM_VALUE param_id bytes: {raw.hex().upper()}"
            )
        else:
            visible += 1
    if visible == 0:
        raise FixtureError("empty PARAM_VALUE param_id")
    return raw.split(b"\0", 1)[0].decode("ascii")


def decode_fixture_frame(frame: bytes, ordinal: int) -> dict[str, Any]:
    prefix = f"frame {ordinal}"
    if len(frame) != FRAME_SIZE:
        raise FixtureError(
            f"{prefix} size mismatch: expected {FRAME_SIZE}, got {len(frame)}"
        )
    if frame[0] != 0xFD:
        raise FixtureError(f"{prefix} is not MAVLink 2")
    payload_length = frame[1]
    incompatibility_flags = frame[2]
    if payload_length != 25:
        raise FixtureError(
            f"{prefix} payload length mismatch: expected 25, got "
            f"{payload_length}"
        )
    if incompatibility_flags != 0:
        raise FixtureError(
            f"{prefix} is signed or has unsupported incompatibility flags: "
            f"0x{incompatibility_flags:02X}"
        )
    message_id = frame[7] | (frame[8] << 8) | (frame[9] << 16)
    if message_id != PARAM_VALUE_MESSAGE_ID:
        raise FixtureError(
            f"{prefix} message id mismatch: expected 22, got {message_id}"
        )
    system_id, component_id = frame[5], frame[6]
    if (system_id, component_id) != EXPECTED_SOURCE:
        raise FixtureError(
            f"{prefix} source mismatch: expected 1/1, got "
            f"{system_id}/{component_id}"
        )
    stored_crc = int.from_bytes(frame[35:37], "little")
    calculated_crc = x25_crc(frame[1:35], PARAM_VALUE_CRC_EXTRA)
    if stored_crc != calculated_crc:
        raise FixtureError(
            f"{prefix} CRC mismatch: stored 0x{stored_crc:04X}, "
            f"calculated 0x{calculated_crc:04X}"
        )

    payload = frame[10:35]
    param_count = int.from_bytes(payload[4:6], "little")
    param_index = int.from_bytes(payload[6:8], "little")
    param_id_raw = payload[8:24]
    param_id = decode_param_id(param_id_raw)
    param_type = payload[24]
    if param_type < 1 or param_type > 10:
        raise FixtureError(
            f"{prefix} invalid PARAM_VALUE type: {param_type}"
        )
    return {
        "sequence": frame[4],
        "system_id": system_id,
        "component_id": component_id,
        "message_id": message_id,
        "payload_length": payload_length,
        "param_count": param_count,
        "param_index": param_index,
        "param_id": param_id,
        "param_id_raw_hex": param_id_raw.hex().upper(),
        "param_type": param_type,
        "value_bits_le_hex": payload[0:4].hex().upper(),
        "stored_crc_hex": f"{stored_crc:04X}",
    }


def validate_fixture_bytes(
    stream: bytes,
    *,
    expected_count: int = EXPECTED_COUNT,
) -> dict[str, Any]:
    if expected_count <= 0:
        raise FixtureError("expected_count must be positive")
    expected_bytes = expected_count * FRAME_SIZE
    if len(stream) != expected_bytes:
        raise FixtureError(
            f"fixture size mismatch: expected {expected_bytes}, got "
            f"{len(stream)}"
        )

    decoded: list[dict[str, Any]] = []
    for ordinal in range(expected_count):
        offset = ordinal * FRAME_SIZE
        decoded.append(
            decode_fixture_frame(stream[offset : offset + FRAME_SIZE], ordinal)
        )

    indexes = [int(item["param_index"]) for item in decoded]
    expected_indexes = list(range(expected_count))
    if indexes != expected_indexes:
        first_bad = next(
            index
            for index, (actual, expected) in enumerate(
                zip(indexes, expected_indexes, strict=True)
            )
            if actual != expected
        )
        raise FixtureError(
            f"PARAM_VALUE order mismatch at fixture frame {first_bad}: "
            f"expected index {first_bad}, got {indexes[first_bad]}"
        )
    counts = {int(item["param_count"]) for item in decoded}
    if counts != {expected_count}:
        raise FixtureError(
            f"PARAM_VALUE param_count mismatch: expected {expected_count}, "
            f"got {sorted(counts)}"
        )
    param_ids = [str(item["param_id"]) for item in decoded]
    if len(set(param_ids)) != expected_count:
        raise FixtureError("PARAM_VALUE param_id values are not unique")

    sequence_discontinuities = 0
    for previous, current in zip(decoded, decoded[1:]):
        expected_sequence = (int(previous["sequence"]) + 1) & 0xFF
        if int(current["sequence"]) != expected_sequence:
            sequence_discontinuities += 1

    return {
        "schema_version": 1,
        "result": "PASS",
        "validation_scope": (
            "byte-exact fixed-frame parse; MAVLink2 framing/source/message/"
            "payload; X25 CRC_EXTRA=220; indexes 0..931; count=932; unique "
            "printable parameter IDs; valid parameter types"
        ),
        "stream_bytes": len(stream),
        "stream_sha256": sha256_bytes(stream),
        "frame_count": len(decoded),
        "frame_size_bytes": FRAME_SIZE,
        "valid_crc_count": len(decoded),
        "crc_failure_count": 0,
        "mavlink2_count": len(decoded),
        "signed_count": 0,
        "source": {"system_id": 1, "component_id": 1},
        "message_id": PARAM_VALUE_MESSAGE_ID,
        "payload_length": 25,
        "param_count": expected_count,
        "first_index": indexes[0],
        "last_index": indexes[-1],
        "unique_index_count": len(set(indexes)),
        "unique_param_id_count": len(set(param_ids)),
        "first_param_id": param_ids[0],
        "last_param_id": param_ids[-1],
        "first_sequence": int(decoded[0]["sequence"]),
        "last_sequence": int(decoded[-1]["sequence"]),
        "sequence_discontinuity_count": sequence_discontinuities,
        "sequence_note": (
            "Original source sequence bytes are retained. Discontinuities "
            "are expected because non-PARAM_VALUE tlog frames are omitted."
        ),
    }


def require_hash(path: Path, expected: str, label: str) -> tuple[bytes, str]:
    try:
        data = path.resolve(strict=True).read_bytes()
    except OSError as exc:
        raise FixtureError(f"cannot read {label}: {path}: {exc}") from exc
    actual = sha256_bytes(data)
    if actual != expected:
        raise FixtureError(
            f"{label} SHA256 mismatch: expected {expected}, got {actual}"
        )
    return data, actual


def verify_acceptance_summary(path: Path) -> tuple[dict[str, Any], str]:
    data, digest = require_hash(
        path, EXPECTED_ACCEPTANCE_SUMMARY_SHA256, "R18 acceptance summary"
    )
    try:
        summary = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FixtureError(f"invalid R18 acceptance summary: {exc}") from exc

    required = {
        "result": "PASS",
        "result_detail": "STRICT_932_AND_HEARTBEAT_SLA_PASS",
    }
    for key, expected in required.items():
        if summary.get(key) != expected:
            raise FixtureError(
                f"R18 acceptance summary {key} mismatch: "
                f"expected {expected!r}, got {summary.get(key)!r}"
            )
    recorded_tlog_hash = summary.get("input", {}).get("sha256")
    if recorded_tlog_hash != EXPECTED_TLOG_SHA256:
        raise FixtureError(
            "R18 acceptance summary does not pin the expected tlog SHA256"
        )
    download = summary.get("parameter_download", {})
    required_download = {
        "result": "PASS_STRICT_EXACT_ORDER",
        "expected_count": EXPECTED_COUNT,
        "indexed_frame_count": EXPECTED_COUNT,
        "unique_index_count": EXPECTED_COUNT,
        "missing_count": 0,
        "duplicate_frame_count": 0,
        "out_of_order_count": 0,
        "count_mismatch_frame_count": 0,
    }
    for key, expected in required_download.items():
        if download.get(key) != expected:
            raise FixtureError(
                f"R18 accepted parameter_download {key} mismatch: "
                f"expected {expected!r}, got {download.get(key)!r}"
            )
    return summary, digest


def extract_exact_frames(
    tlog_path: Path,
) -> tuple[bytes, list[dict[str, Any]], dict[str, Any]]:
    # Import only after the source tool and its definitions have been pinned.
    import analyze_mission_planner_tlog as analyzer

    data, input_snapshot = analyzer.read_input_snapshot(tlog_path)
    if not input_snapshot["stable_during_read"]:
        raise FixtureError("R18 tlog changed while it was being read")
    if input_snapshot["sha256"] != EXPECTED_TLOG_SHA256:
        raise FixtureError(
            "R18 tlog SHA256 changed after the pinned provenance check"
        )
    definitions = analyzer.load_definitions(DEFINITIONS)
    records, tlog, integrity = analyzer.parse_tlog(data, definitions)
    if not tlog["exact_eof"]:
        raise FixtureError("R18 tlog parser did not reach exact EOF")
    if tlog["nonmonotonic_timestamp_count"] != 0:
        raise FixtureError("R18 tlog timestamps are non-monotonic")
    if integrity["known_bad_crc_count"] != 0:
        raise FixtureError("R18 tlog contains a known bad CRC")
    if integrity["known_bad_payload_length_count"] != 0:
        raise FixtureError("R18 tlog contains a known bad payload length")
    if integrity["unknown_mavlink2_incompatibility_flags_count"] != 0:
        raise FixtureError("R18 tlog contains unsupported MAVLink2 flags")

    _, _, first_request, bad_requests = analyzer.decode_requests(records)
    if first_request is None or bad_requests:
        raise FixtureError("R18 tlog lacks one clean eligible list request")
    download, completion, bad_parameters = analyzer.analyze_parameter_download(
        records, first_request, EXPECTED_COUNT
    )
    if not download["valid"] or completion is None or bad_parameters:
        raise FixtureError("R18 tlog does not contain the accepted strict stream")
    source_frames = download["indexed_frames"]
    if len(source_frames) != EXPECTED_COUNT:
        raise FixtureError(
            f"R18 extraction count mismatch: expected {EXPECTED_COUNT}, got "
            f"{len(source_frames)}"
        )

    wire_frames: list[bytes] = []
    index_entries: list[dict[str, Any]] = []
    for fixture_ordinal, source in enumerate(source_frames):
        frame_offset = int(source["frame_offset"])
        frame_size = int(source["frame_size"])
        raw = data[frame_offset : frame_offset + frame_size]
        decoded = decode_fixture_frame(raw, fixture_ordinal)
        if int(decoded["param_index"]) != fixture_ordinal:
            raise FixtureError(
                f"source extraction index mismatch at {fixture_ordinal}"
            )
        fixture_offset = fixture_ordinal * FRAME_SIZE
        entry = {
            "fixture_ordinal": fixture_ordinal,
            "fixture_offset": fixture_offset,
            "frame_size": frame_size,
            "frame_sha256": sha256_bytes(raw),
            "source_tlog_ordinal": int(source["ordinal"]),
            "source_tlog_frame_offset": frame_offset,
            "source_timestamp_us": int(source["timestamp_us"]),
            **decoded,
        }
        wire_frames.append(raw)
        index_entries.append(entry)

    stream = b"".join(wire_frames)
    extraction = {
        "selection_rule": (
            "first eligible GCS 255/190 PARAM_REQUEST_LIST to 1/1, then the "
            "accepted analyzer's first exact ordered source-1/1 PARAM_VALUE "
            "indexes 0..931 through first index 931"
        ),
        "eligible_request_ordinal": int(first_request["ordinal"]),
        "eligible_request_timestamp_us": int(first_request["timestamp_us"]),
        "first_source_ordinal": int(source_frames[0]["ordinal"]),
        "last_source_ordinal": int(source_frames[-1]["ordinal"]),
        "first_source_timestamp_us": int(source_frames[0]["timestamp_us"]),
        "last_source_timestamp_us": int(source_frames[-1]["timestamp_us"]),
        "source_record_count": int(tlog["record_count"]),
        "source_exact_eof": bool(tlog["exact_eof"]),
    }
    return stream, index_entries, {
        "input_snapshot": input_snapshot,
        "extraction": extraction,
    }


def generate_fixture(
    tlog_path: Path,
    acceptance_summary_path: Path,
    output_dir: Path,
) -> dict[str, Any]:
    tlog_path = Path(tlog_path)
    acceptance_summary_path = Path(acceptance_summary_path)
    output_dir = Path(output_dir)
    if output_dir.exists():
        raise FixtureError(f"output directory already exists: {output_dir}")

    acceptance, acceptance_digest = verify_acceptance_summary(
        acceptance_summary_path
    )
    tlog_data, tlog_digest = require_hash(
        tlog_path, EXPECTED_TLOG_SHA256, "accepted R18 tlog"
    )
    del tlog_data
    _, analyzer_digest = require_hash(
        ANALYZER, EXPECTED_ANALYZER_SHA256, "R18 tlog analyzer"
    )
    _, definitions_digest = require_hash(
        DEFINITIONS, EXPECTED_DEFINITIONS_SHA256, "MAVLink definitions"
    )

    stream, index_entries, source = extract_exact_frames(tlog_path)
    validation = validate_fixture_bytes(stream)
    index_bytes = b"".join(
        (
            json.dumps(entry, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
        for entry in index_entries
    )
    validation_bytes = canonical_json(validation)

    generator_digest = sha256_file(Path(__file__))
    manifest = {
        "schema_version": 1,
        "fixture_id": "R19-HS-G2-R18-ACCEPTED-PARAM-VALUE-932-V1",
        "result": "PASS",
        "measurement_only": True,
        "hardware_access": False,
        "format": (
            "concatenated exact unsigned MAVLink2 PARAM_VALUE frames; no "
            "timestamps, delimiters, or interleaved messages"
        ),
        "source_evidence": {
            "test_id": acceptance["test_id"],
            "tlog_path": repo_path(tlog_path),
            "tlog_bytes": int(source["input_snapshot"]["size_bytes"]),
            "tlog_sha256": tlog_digest,
            "stable_during_read": bool(
                source["input_snapshot"]["stable_during_read"]
            ),
            "acceptance_summary_path": repo_path(acceptance_summary_path),
            "acceptance_summary_sha256": acceptance_digest,
            "acceptance_result": acceptance["result"],
            "acceptance_result_detail": acceptance["result_detail"],
        },
        "extractor": {
            "generator_path": repo_path(Path(__file__)),
            "generator_sha256": generator_digest,
            "analyzer_path": repo_path(ANALYZER),
            "analyzer_sha256": analyzer_digest,
            "definitions_path": repo_path(DEFINITIONS),
            "definitions_sha256": definitions_digest,
        },
        "selection": source["extraction"],
        "fixture": {
            "stream_file": STREAM_NAME,
            "stream_bytes": len(stream),
            "stream_sha256": sha256_bytes(stream),
            "frame_count": EXPECTED_COUNT,
            "frame_size_bytes": FRAME_SIZE,
            "index_file": INDEX_NAME,
            "index_bytes": len(index_bytes),
            "index_sha256": sha256_bytes(index_bytes),
            "validation_file": VALIDATION_NAME,
            "validation_sha256": sha256_bytes(validation_bytes),
        },
        "validation": {
            "result": validation["result"],
            "crc_failure_count": validation["crc_failure_count"],
            "first_index": validation["first_index"],
            "last_index": validation["last_index"],
            "unique_index_count": validation["unique_index_count"],
            "unique_param_id_count": validation["unique_param_id_count"],
        },
    }
    manifest_bytes = canonical_json(manifest)

    output_dir.mkdir(parents=True, exist_ok=False)
    (output_dir / STREAM_NAME).write_bytes(stream)
    (output_dir / INDEX_NAME).write_bytes(index_bytes)
    (output_dir / VALIDATION_NAME).write_bytes(validation_bytes)
    (output_dir / MANIFEST_NAME).write_bytes(manifest_bytes)
    checksum_lines = []
    for name in (STREAM_NAME, INDEX_NAME, VALIDATION_NAME, MANIFEST_NAME):
        checksum_lines.append(
            f"{sha256_file(output_dir / name)} *{name}\n"
        )
    (output_dir / CHECKSUMS_NAME).write_text(
        "".join(checksum_lines), encoding="ascii", newline=""
    )
    return manifest


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_TLOG)
    parser.add_argument(
        "--acceptance-summary",
        type=Path,
        default=DEFAULT_ACCEPTANCE_SUMMARY,
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = generate_fixture(
            args.input, args.acceptance_summary, args.output_dir
        )
    except FixtureError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(manifest, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
