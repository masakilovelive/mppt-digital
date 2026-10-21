#!/usr/bin/env python3
"""Strictly analyze a Mission Planner ``.tlog`` acceptance capture.

Mission Planner telemetry logs are a sequence of an eight-byte big-endian
Unix-epoch timestamp in microseconds followed by exactly one MAVLink 1 or
MAVLink 2 frame.  Both packets sent by Mission Planner and packets received
from the vehicle are present in the same file; this analyzer therefore uses
the exact source identities 255/190 and 1/1 to keep the two directions apart.

The PASS decision is intentionally narrow: at least one GCS
PARAM_REQUEST_LIST for 1/1, an exact ordered parameter list, and primary
vehicle HEARTBEAT continuity from the first list request through parameter
completion.  A tlog contains packets accepted by Mission Planner, not the raw
serial byte stream, so it cannot by itself prove that no corrupt/noise bytes
were rejected before logging.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from hil_analyze_capture import load_definitions, x25_crc


SCHEMA_VERSION = 1
DEFAULT_EXPECTED_COUNT = 932
MAX_EXPECTED_COUNT = 32768
DEFAULT_HEARTBEAT_LIMIT_US = 2_500_000
GCS_SOURCE = (255, 190)
VEHICLE_SOURCE = (1, 1)

HEARTBEAT_ID = 0
PARAM_REQUEST_READ_ID = 20
PARAM_REQUEST_LIST_ID = 21
PARAM_VALUE_ID = 22
RELEVANT_IDS = {
    HEARTBEAT_ID,
    PARAM_REQUEST_READ_ID,
    PARAM_REQUEST_LIST_ID,
    PARAM_VALUE_ID,
}
EXPECTED_RELEVANT_DEFINITIONS = {
    HEARTBEAT_ID: (50, 9, 9),
    PARAM_REQUEST_READ_ID: (214, 20, 20),
    PARAM_REQUEST_LIST_ID: (159, 2, 2),
    PARAM_VALUE_ID: (220, 25, 25),
}
DEFAULT_DEFINITIONS = (
    Path(__file__).resolve().parents[1] / "core" / "src"
    / "mavlink_frame.cpp"
)


def file_sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def file_sha256(path: Path) -> str:
    return file_sha256_bytes(path.read_bytes())


def increment(counter: Counter[int], value: int) -> None:
    counter[value] += 1


def counter_json(counter: Counter[int]) -> dict[str, int]:
    return {str(key): value for key, value in sorted(counter.items())}


def anomaly(
    kind: str,
    *,
    offset: int,
    ordinal: int | None = None,
    **details: Any,
) -> dict[str, Any]:
    result: dict[str, Any] = {"kind": kind, "offset": offset}
    if ordinal is not None:
        result["ordinal"] = ordinal
    result.update(details)
    return result


def read_input_snapshot(path: Path) -> tuple[bytes, dict[str, Any]]:
    resolved = path.resolve(strict=True)
    before = resolved.stat()
    with resolved.open("rb") as handle:
        data = handle.read()
    after = resolved.stat()
    stable = (
        before.st_size == after.st_size == len(data)
        and before.st_mtime_ns == after.st_mtime_ns
    )
    return data, {
        "path": str(resolved),
        "size_bytes": len(data),
        "sha256": file_sha256_bytes(data),
        "filesystem_size_before": before.st_size,
        "filesystem_size_after": after.st_size,
        "filesystem_mtime_ns_before": before.st_mtime_ns,
        "filesystem_mtime_ns_after": after.st_mtime_ns,
        "stable_during_read": stable,
    }


def parse_tlog(
    data: bytes,
    definitions: dict[int, tuple[int, int, int]],
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    records: list[dict[str, Any]] = []
    anomalies: list[dict[str, Any]] = []
    bad_crc_records: list[dict[str, Any]] = []
    bad_length_records: list[dict[str, Any]] = []
    unsupported_ids: Counter[int] = Counter()
    mavlink1_count = 0
    mavlink2_count = 0
    signed_count = 0
    unknown_incompatibility_flags_count = 0
    truncated_timestamp_bytes = 0
    truncated_header_count = 0
    truncated_frame_count = 0
    bad_magic_count = 0
    known_bad_crc_count = 0
    relevant_bad_crc_count = 0
    known_bad_payload_length_count = 0
    nonmonotonic_timestamp_count = 0
    nonmonotonic_timestamps: list[dict[str, Any]] = []
    previous_timestamp: int | None = None
    offset = 0

    while offset < len(data):
        timestamp_offset = offset
        remaining = len(data) - offset
        if remaining < 8:
            truncated_timestamp_bytes = remaining
            anomalies.append(
                anomaly(
                    "truncated_timestamp",
                    offset=timestamp_offset,
                    remaining_bytes=remaining,
                    required_bytes=8,
                )
            )
            break

        timestamp_us = int.from_bytes(data[offset : offset + 8], "big")
        offset += 8
        ordinal = len(records)
        if previous_timestamp is not None and timestamp_us < previous_timestamp:
            nonmonotonic_timestamp_count += 1
            event = {
                "ordinal": ordinal,
                "timestamp_offset": timestamp_offset,
                "previous_timestamp_us": previous_timestamp,
                "timestamp_us": timestamp_us,
            }
            nonmonotonic_timestamps.append(event)
            anomalies.append(
                anomaly(
                    "nonmonotonic_timestamp",
                    offset=timestamp_offset,
                    ordinal=ordinal,
                    previous_timestamp_us=previous_timestamp,
                    timestamp_us=timestamp_us,
                )
            )
        previous_timestamp = timestamp_us

        frame_offset = offset
        if offset >= len(data):
            truncated_header_count += 1
            anomalies.append(
                anomaly(
                    "missing_frame_after_timestamp",
                    offset=frame_offset,
                    ordinal=ordinal,
                )
            )
            break
        magic = data[offset]
        if magic not in (0xFE, 0xFD):
            bad_magic_count += 1
            anomalies.append(
                anomaly(
                    "bad_magic",
                    offset=frame_offset,
                    ordinal=ordinal,
                    actual=f"0x{magic:02X}",
                    expected=["0xFE", "0xFD"],
                )
            )
            break

        minimum_header = 6 if magic == 0xFE else 10
        if len(data) - offset < minimum_header:
            truncated_header_count += 1
            anomalies.append(
                anomaly(
                    "truncated_mavlink_header",
                    offset=frame_offset,
                    ordinal=ordinal,
                    remaining_bytes=len(data) - offset,
                    required_bytes=minimum_header,
                    version=1 if magic == 0xFE else 2,
                )
            )
            break

        payload_length = data[offset + 1]
        if magic == 0xFE:
            version = 1
            signed = False
            incompatibility_flags = 0
            frame_size = payload_length + 8
            header_size = 6
            checksum_offset = 6 + payload_length
            sequence = data[offset + 2]
            system_id = data[offset + 3]
            component_id = data[offset + 4]
            message_id = data[offset + 5]
        else:
            version = 2
            incompatibility_flags = data[offset + 2]
            signed = bool(incompatibility_flags & 0x01)
            signature_size = 13 if signed else 0
            frame_size = payload_length + 12 + signature_size
            header_size = 10
            checksum_offset = 10 + payload_length
            sequence = data[offset + 4]
            system_id = data[offset + 5]
            component_id = data[offset + 6]
            message_id = (
                data[offset + 7]
                | (data[offset + 8] << 8)
                | (data[offset + 9] << 16)
            )
            unknown_flags = incompatibility_flags & ~0x01
            if unknown_flags:
                unknown_incompatibility_flags_count += 1
                anomalies.append(
                    anomaly(
                        "unknown_mavlink2_incompatibility_flags",
                        offset=frame_offset,
                        ordinal=ordinal,
                        flags=f"0x{incompatibility_flags:02X}",
                        unknown_flags=f"0x{unknown_flags:02X}",
                    )
                )

        if len(data) - offset < frame_size:
            truncated_frame_count += 1
            anomalies.append(
                anomaly(
                    "truncated_mavlink_frame",
                    offset=frame_offset,
                    ordinal=ordinal,
                    remaining_bytes=len(data) - offset,
                    required_bytes=frame_size,
                    message_id=message_id,
                    payload_length=payload_length,
                    signed=signed,
                )
            )
            break

        if version == 1:
            mavlink1_count += 1
        else:
            mavlink2_count += 1
            if signed:
                signed_count += 1

        frame = data[offset : offset + frame_size]
        payload = frame[header_size : header_size + payload_length]
        stored_crc = int.from_bytes(
            frame[checksum_offset : checksum_offset + 2], "little"
        )
        definition = definitions.get(message_id)
        definition_known = definition is not None
        crc_valid: bool | None = None
        payload_length_valid: bool | None = None
        if definition is None:
            increment(unsupported_ids, message_id)
        else:
            crc_extra, minimum_length, maximum_length = definition
            calculated_crc = x25_crc(frame[1:checksum_offset], crc_extra)
            crc_valid = stored_crc == calculated_crc
            # Mission Planner deliberately strips all trailing zero payload
            # bytes from MAVLink2, including bytes below dialect min_length.
            # MAVLink1 remains fixed at the dialect minimum payload length.
            payload_length_valid = (
                payload_length == minimum_length
                if version == 1
                else payload_length <= maximum_length
            )
            if not crc_valid:
                known_bad_crc_count += 1
                if message_id in RELEVANT_IDS:
                    relevant_bad_crc_count += 1
                event = {
                    "ordinal": ordinal,
                    "frame_offset": frame_offset,
                    "timestamp_us": timestamp_us,
                    "message_id": message_id,
                    "stored_crc": stored_crc,
                    "calculated_crc": calculated_crc,
                }
                bad_crc_records.append(event)
                anomalies.append(
                    anomaly(
                        "bad_mavlink_crc",
                        offset=frame_offset,
                        ordinal=ordinal,
                        timestamp_us=timestamp_us,
                        message_id=message_id,
                        stored_crc=stored_crc,
                        calculated_crc=calculated_crc,
                    )
                )
            if not payload_length_valid:
                known_bad_payload_length_count += 1
                event = {
                    "ordinal": ordinal,
                    "frame_offset": frame_offset,
                    "timestamp_us": timestamp_us,
                    "version": version,
                    "message_id": message_id,
                    "payload_length": payload_length,
                    "minimum_length": minimum_length,
                    "maximum_length": maximum_length,
                }
                bad_length_records.append(event)
                anomalies.append(
                    anomaly(
                        "bad_known_payload_length",
                        offset=frame_offset,
                        ordinal=ordinal,
                        timestamp_us=timestamp_us,
                        version=version,
                        message_id=message_id,
                        payload_length=payload_length,
                        minimum_length=minimum_length,
                        maximum_length=maximum_length,
                    )
                )

        record = {
            "ordinal": ordinal,
            "timestamp_offset": timestamp_offset,
            "frame_offset": frame_offset,
            "timestamp_us": timestamp_us,
            "version": version,
            "signed": signed,
            "incompatibility_flags": incompatibility_flags,
            "frame_size": frame_size,
            "payload_length": payload_length,
            "sequence": sequence,
            "system_id": system_id,
            "component_id": component_id,
            "message_id": message_id,
            "stored_crc": stored_crc,
            "definition_known": definition_known,
            "crc_valid": crc_valid,
            "payload_length_valid": payload_length_valid,
            "_payload": payload,
        }
        records.append(record)
        offset += frame_size

    exact_eof = (
        offset == len(data)
        and truncated_timestamp_bytes == 0
        and truncated_header_count == 0
        and truncated_frame_count == 0
        and bad_magic_count == 0
    )
    tlog = {
        "format": "repeated_be_u64_epoch_us_plus_one_mavlink_frame",
        "record_count": len(records),
        "mavlink1_frame_count": mavlink1_count,
        "mavlink2_frame_count": mavlink2_count,
        "signed_mavlink2_frame_count": signed_count,
        "first_timestamp_us": records[0]["timestamp_us"] if records else None,
        "last_timestamp_us": records[-1]["timestamp_us"] if records else None,
        "nonmonotonic_timestamp_count": nonmonotonic_timestamp_count,
        "nonmonotonic_timestamps": nonmonotonic_timestamps,
        "exact_eof": exact_eof,
        "bytes_consumed": offset,
        "unconsumed_bytes": len(data) - offset,
    }
    integrity = {
        "known_bad_crc_count": known_bad_crc_count,
        "relevant_bad_crc_count": relevant_bad_crc_count,
        "known_bad_payload_length_count": known_bad_payload_length_count,
        "unknown_definition_frame_count": sum(unsupported_ids.values()),
        "unknown_definition_message_ids": counter_json(unsupported_ids),
        "unknown_mavlink2_incompatibility_flags_count": (
            unknown_incompatibility_flags_count
        ),
        "bad_magic_count": bad_magic_count,
        "truncated_timestamp_bytes": truncated_timestamp_bytes,
        "truncated_header_count": truncated_header_count,
        "truncated_frame_count": truncated_frame_count,
        "bad_crc_records": bad_crc_records,
        "bad_payload_length_records": bad_length_records,
        "anomaly_count": len(anomalies),
        "anomalies": anomalies,
        "mavlink_crc_revalidated": True,
        "signatures_cryptographically_verified": False,
    }
    return records, tlog, integrity


def record_usable(record: dict[str, Any]) -> bool:
    return bool(
        record["definition_known"]
        and record["crc_valid"]
        and record["payload_length_valid"]
        and not (int(record["incompatibility_flags"]) & ~0x01)
    )


def relevant_payload_length_valid(record: dict[str, Any]) -> bool:
    message_id = int(record["message_id"])
    payload_length = int(record["payload_length"])
    version = int(record["version"])
    if message_id == HEARTBEAT_ID:
        return payload_length == 9
    if message_id == PARAM_REQUEST_LIST_ID:
        return payload_length == 2
    if message_id == PARAM_VALUE_ID:
        return payload_length == 25
    if message_id == PARAM_REQUEST_READ_ID:
        return payload_length == 20 if version == 1 else 4 <= payload_length <= 20
    return True


def public_frame(record: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in record.items()
        if not key.startswith("_")
    }


def decode_requests(
    records: list[dict[str, Any]],
) -> tuple[
    dict[str, Any],
    dict[str, Any],
    dict[str, Any] | None,
    list[dict[str, Any]],
]:
    lists: list[dict[str, Any]] = []
    reads: list[dict[str, Any]] = []
    relevant_bad_payload_records: list[dict[str, Any]] = []

    for record in records:
        message_id = int(record["message_id"])
        if message_id not in (PARAM_REQUEST_LIST_ID, PARAM_REQUEST_READ_ID):
            continue
        if not record_usable(record):
            continue
        if not relevant_payload_length_valid(record):
            relevant_bad_payload_records.append(
                {
                    "ordinal": record["ordinal"],
                    "frame_offset": record["frame_offset"],
                    "timestamp_us": record["timestamp_us"],
                    "message_id": message_id,
                    "version": record["version"],
                    "payload_length": record["payload_length"],
                }
            )
            continue

        payload = bytes(record["_payload"])
        if message_id == PARAM_REQUEST_LIST_ID:
            event = public_frame(record)
            event.update(
                {
                    "target_system": payload[0],
                    "target_component": payload[1],
                }
            )
            event["eligible"] = (
                (record["system_id"], record["component_id"]) == GCS_SOURCE
                and (payload[0], payload[1]) == VEHICLE_SOURCE
            )
            lists.append(event)
        else:
            padded = payload.ljust(20, b"\0")
            raw_id = padded[4:20]
            event = public_frame(record)
            event.update(
                {
                    "param_index": int.from_bytes(
                        padded[0:2], "little", signed=True
                    ),
                    "target_system": padded[2],
                    "target_component": padded[3],
                    "param_id": raw_id.split(b"\0", 1)[0].decode(
                        "ascii", errors="replace"
                    ),
                    "param_id_raw_hex": raw_id.hex().upper(),
                }
            )
            event["eligible"] = (
                (record["system_id"], record["component_id"]) == GCS_SOURCE
                and (padded[2], padded[3]) == VEHICLE_SOURCE
            )
            reads.append(event)

    eligible_lists = [event for event in lists if event["eligible"]]
    eligible_reads = [event for event in reads if event["eligible"]]
    index_counts = Counter(
        int(event["param_index"])
        for event in eligible_reads
        if int(event["param_index"]) >= 0
    )
    payload_lengths = Counter(
        int(event["payload_length"]) for event in reads
    )
    list_summary = {
        "count": len(lists),
        "eligible_count": len(eligible_lists),
        "wrong_route_count": len(lists) - len(eligible_lists),
        "frames": lists,
    }
    read_summary = {
        "count": len(reads),
        "eligible_count": len(eligible_reads),
        "wrong_route_count": len(reads) - len(eligible_reads),
        "payload_length_counts": counter_json(payload_lengths),
        "unique_requested_indexes": len(index_counts),
        "first_index": min(index_counts) if index_counts else None,
        "last_index": max(index_counts) if index_counts else None,
        "index_occurrences": counter_json(index_counts),
        "named_request_count": sum(
            1 for event in eligible_reads if int(event["param_index"]) < 0
        ),
        "first_frames": reads[:10],
        "last_frames": reads[-10:] if len(reads) > 10 else [],
    }
    m0 = eligible_lists[0] if eligible_lists else None
    return (
        list_summary,
        read_summary,
        m0,
        relevant_bad_payload_records,
    )


def valid_param_id(raw_id: bytes) -> bool:
    saw_zero = False
    visible = 0
    for value in raw_id:
        if value == 0:
            saw_zero = True
        elif saw_zero or value < 0x20 or value > 0x7E:
            return False
        else:
            visible += 1
    return visible > 0


def analyze_parameter_download(
    records: list[dict[str, Any]],
    m0: dict[str, Any] | None,
    expected_count: int,
) -> tuple[
    dict[str, Any],
    dict[str, Any] | None,
    list[dict[str, Any]],
]:
    indexed_events: list[dict[str, Any]] = []
    sentinel_events: list[dict[str, Any]] = []
    wrong_source_events: list[dict[str, Any]] = []
    pre_request_count = 0
    bad_payload_records: list[dict[str, Any]] = []
    index_counter: Counter[int] = Counter()
    id_counter: Counter[str] = Counter()
    out_of_order: list[dict[str, Any]] = []
    out_of_range: list[int] = []
    count_mismatch_count = 0
    invalid_param_id_count = 0
    invalid_param_type_count = 0
    next_expected_index = 0
    completion_record: dict[str, Any] | None = None
    m0_ordinal = int(m0["ordinal"]) if m0 is not None else None

    for record in records:
        if int(record["message_id"]) != PARAM_VALUE_ID:
            continue
        if m0_ordinal is None or int(record["ordinal"]) <= m0_ordinal:
            pre_request_count += 1
            continue
        if not record_usable(record):
            continue
        if not relevant_payload_length_valid(record):
            bad_payload_records.append(
                {
                    "ordinal": record["ordinal"],
                    "frame_offset": record["frame_offset"],
                    "timestamp_us": record["timestamp_us"],
                    "message_id": PARAM_VALUE_ID,
                    "version": record["version"],
                    "payload_length": record["payload_length"],
                }
            )
            continue
        if (record["system_id"], record["component_id"]) != VEHICLE_SOURCE:
            wrong_source_events.append(public_frame(record))
            continue

        payload = bytes(record["_payload"])
        param_count = int.from_bytes(payload[4:6], "little")
        param_index = int.from_bytes(payload[6:8], "little")
        raw_id = payload[8:24]
        param_id = raw_id.split(b"\0", 1)[0].decode(
            "ascii", errors="replace"
        )
        param_type = payload[24]
        event = public_frame(record)
        event.update(
            {
                "param_count": param_count,
                "param_index": param_index,
                "param_id": param_id,
                "param_id_raw_hex": raw_id.hex().upper(),
                "param_type": param_type,
                "value_bits_hex": payload[0:4][::-1].hex().upper(),
            }
        )
        if param_index == 0xFFFF:
            event["classification"] = "sentinel"
            sentinel_events.append(event)
            continue

        event["classification"] = "indexed"
        indexed_events.append(event)
        index_counter[param_index] += 1
        if param_count != expected_count:
            count_mismatch_count += 1
        if not valid_param_id(raw_id):
            invalid_param_id_count += 1
        else:
            id_counter[param_id] += 1
        if not 1 <= param_type <= 10:
            invalid_param_type_count += 1
        if not 0 <= param_index < expected_count:
            out_of_range.append(param_index)
            continue
        if index_counter[param_index] > 1:
            continue
        if param_index != next_expected_index:
            out_of_order.append(
                {
                    "ordinal": record["ordinal"],
                    "timestamp_us": record["timestamp_us"],
                    "param_index": param_index,
                    "expected_index": next_expected_index,
                }
            )
        else:
            next_expected_index += 1
        if param_index == expected_count - 1 and completion_record is None:
            completion_record = record
            # The strict download window ends at the first expected final
            # index.  Mission Planner may continue issuing recovery reads
            # after that point; their PARAM_VALUE responses belong to the
            # recovery phase and must not alter the original-stream counts.
            break

    missing = sorted(set(range(expected_count)) - set(index_counter))
    duplicates = [
        {"index": index, "occurrences": occurrences,
         "duplicate_frames": occurrences - 1}
        for index, occurrences in sorted(index_counter.items())
        if occurrences > 1
    ]
    duplicate_frame_count = sum(
        item["duplicate_frames"] for item in duplicates
    )
    duplicate_ids = [
        {"param_id": param_id, "occurrences": occurrences}
        for param_id, occurrences in sorted(id_counter.items())
        if occurrences > 1
    ]
    first_index = (
        int(indexed_events[0]["param_index"]) if indexed_events else None
    )
    last_index = (
        int(indexed_events[-1]["param_index"]) if indexed_events else None
    )
    valid = bool(
        m0 is not None
        and len(indexed_events) == expected_count
        and len(index_counter) == expected_count
        and not missing
        and duplicate_frame_count == 0
        and not out_of_order
        and not out_of_range
        and count_mismatch_count == 0
        and not wrong_source_events
        and not bad_payload_records
        and invalid_param_id_count == 0
        and not duplicate_ids
        and len(id_counter) == expected_count
        and invalid_param_type_count == 0
        and first_index == 0
        and last_index == expected_count - 1
        and next_expected_index == expected_count
    )
    summary = {
        "valid": valid,
        "source": {
            "system_id": VEHICLE_SOURCE[0],
            "component_id": VEHICLE_SOURCE[1],
        },
        "expected_count": expected_count,
        "expected_indexes": f"0..{expected_count - 1}",
        "indexed_frame_count": len(indexed_events),
        "unique_index_count": len(index_counter),
        "missing_count": len(missing),
        "missing_indexes": missing,
        "duplicate_frame_count": duplicate_frame_count,
        "duplicates": duplicates,
        "out_of_order_count": len(out_of_order),
        "out_of_order_events": out_of_order,
        "out_of_range_count": len(out_of_range),
        "out_of_range_indexes": sorted(set(out_of_range)),
        "count_mismatch_frame_count": count_mismatch_count,
        "wrong_source_frame_count": len(wrong_source_events),
        "wrong_source_frames": wrong_source_events,
        "bad_payload_length_count": len(bad_payload_records),
        "bad_payload_length_records": bad_payload_records,
        "first_index": first_index,
        "last_index": last_index,
        "next_expected_index": next_expected_index,
        "unique_param_id_count": len(id_counter),
        "duplicate_param_id_count": len(duplicate_ids),
        "duplicate_param_ids": duplicate_ids,
        "invalid_param_id_count": invalid_param_id_count,
        "invalid_param_type_count": invalid_param_type_count,
        "pre_request_param_value_count": pre_request_count,
        "sentinel_frame_count": len(sentinel_events),
        "sentinel_frames": sentinel_events,
        "completion_timestamp_us": (
            int(completion_record["timestamp_us"])
            if completion_record is not None else None
        ),
        "completion_ordinal": (
            int(completion_record["ordinal"])
            if completion_record is not None else None
        ),
        "indexed_frames": indexed_events,
    }
    return summary, completion_record, bad_payload_records


def analyze_heartbeat(
    records: list[dict[str, Any]],
    m0: dict[str, Any] | None,
    completion_record: dict[str, Any] | None,
    heartbeat_limit_us: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    bad_payload_records: list[dict[str, Any]] = []
    if m0 is None:
        return {
            "valid": False,
            "source": {
                "system_id": VEHICLE_SOURCE[0],
                "component_id": VEHICLE_SOURCE[1],
            },
            "window_start_timestamp_us": None,
            "window_end_timestamp_us": None,
            "maximum_gap_limit_us": heartbeat_limit_us,
            "maximum_gap_limit_ms": heartbeat_limit_us / 1000.0,
            "count": 0,
            "maximum_gap_us": None,
            "maximum_gap_ms": None,
            "exceedance_count": 0,
            "exceedances": [],
            "gaps": [],
            "timestamps_us": [],
            "failure_reason": "no eligible PARAM_REQUEST_LIST",
        }, []

    start_ordinal = int(m0["ordinal"])
    start_us = int(m0["timestamp_us"])
    if completion_record is not None:
        end_ordinal = int(completion_record["ordinal"])
        end_us = int(completion_record["timestamp_us"])
        end_basis = "first_expected_last_index"
    elif records:
        end_ordinal = int(records[-1]["ordinal"])
        end_us = int(records[-1]["timestamp_us"])
        end_basis = "last_complete_tlog_record_no_parameter_completion"
    else:
        end_ordinal = start_ordinal
        end_us = start_us
        end_basis = "request_only"

    heartbeat_records: list[dict[str, Any]] = []
    other_source_count = 0
    for record in records:
        if int(record["message_id"]) != HEARTBEAT_ID:
            continue
        ordinal = int(record["ordinal"])
        if ordinal < start_ordinal or ordinal > end_ordinal:
            continue
        if not record_usable(record):
            continue
        if not relevant_payload_length_valid(record):
            bad_payload_records.append(
                {
                    "ordinal": ordinal,
                    "frame_offset": record["frame_offset"],
                    "timestamp_us": record["timestamp_us"],
                    "message_id": HEARTBEAT_ID,
                    "version": record["version"],
                    "payload_length": record["payload_length"],
                }
            )
            continue
        if (record["system_id"], record["component_id"]) != VEHICLE_SOURCE:
            other_source_count += 1
            continue
        heartbeat_records.append(record)

    gaps: list[dict[str, Any]] = []
    if heartbeat_records:
        first_us = int(heartbeat_records[0]["timestamp_us"])
        gaps.append(
            {
                "kind": "edge_from_request",
                "from_timestamp_us": start_us,
                "to_timestamp_us": first_us,
                "gap_us": first_us - start_us,
                "gap_ms": (first_us - start_us) / 1000.0,
            }
        )
        for before, after in zip(heartbeat_records, heartbeat_records[1:]):
            before_us = int(before["timestamp_us"])
            after_us = int(after["timestamp_us"])
            gaps.append(
                {
                    "kind": "consecutive",
                    "from_timestamp_us": before_us,
                    "to_timestamp_us": after_us,
                    "gap_us": after_us - before_us,
                    "gap_ms": (after_us - before_us) / 1000.0,
                }
            )
        last_us = int(heartbeat_records[-1]["timestamp_us"])
        gaps.append(
            {
                "kind": (
                    "tail_to_parameter_completion"
                    if completion_record is not None
                    else "tail_to_window_end"
                ),
                "from_timestamp_us": last_us,
                "to_timestamp_us": end_us,
                "gap_us": end_us - last_us,
                "gap_ms": (end_us - last_us) / 1000.0,
            }
        )
    maximum_gap_us = max((int(gap["gap_us"]) for gap in gaps), default=None)
    exceedances = [
        gap for gap in gaps if int(gap["gap_us"]) > heartbeat_limit_us
    ]
    valid = bool(
        len(heartbeat_records) >= 2
        and not exceedances
        and not bad_payload_records
    )
    return {
        "valid": valid,
        "source": {
            "system_id": VEHICLE_SOURCE[0],
            "component_id": VEHICLE_SOURCE[1],
        },
        "window_start_timestamp_us": start_us,
        "window_start_ordinal": start_ordinal,
        "window_end_timestamp_us": end_us,
        "window_end_ordinal": end_ordinal,
        "window_end_basis": end_basis,
        "maximum_gap_limit_us": heartbeat_limit_us,
        "maximum_gap_limit_ms": heartbeat_limit_us / 1000.0,
        "count": len(heartbeat_records),
        "ignored_other_source_count": other_source_count,
        "bad_payload_length_count": len(bad_payload_records),
        "bad_payload_length_records": bad_payload_records,
        "maximum_gap_us": maximum_gap_us,
        "maximum_gap_ms": (
            maximum_gap_us / 1000.0 if maximum_gap_us is not None else None
        ),
        "exceedance_count": len(exceedances),
        "exceedances": exceedances,
        "gaps": gaps,
        "timestamps_us": [
            int(record["timestamp_us"]) for record in heartbeat_records
        ],
        "failure_reason": (
            None
            if valid
            else "need at least two exact-source heartbeats, valid payloads, "
                 "and every full-window gap within the limit"
        ),
    }, bad_payload_records


def analyze(
    input_path: Path,
    *,
    expected_count: int = DEFAULT_EXPECTED_COUNT,
    heartbeat_limit_us: int = DEFAULT_HEARTBEAT_LIMIT_US,
    definitions_path: Path = DEFAULT_DEFINITIONS,
) -> dict[str, Any]:
    if not 1 <= expected_count <= MAX_EXPECTED_COUNT:
        raise ValueError(
            f"expected_count must be in 1..{MAX_EXPECTED_COUNT}"
        )
    if heartbeat_limit_us <= 0:
        raise ValueError("heartbeat_limit_us must be positive")
    definitions = load_definitions(definitions_path)
    for message_id, expected in EXPECTED_RELEVANT_DEFINITIONS.items():
        if definitions.get(message_id) != expected:
            raise ValueError(
                f"MAVLink definition mismatch for message {message_id}: "
                f"expected {expected}, got {definitions.get(message_id)}"
            )

    data, input_record = read_input_snapshot(input_path)
    records, tlog, integrity = parse_tlog(data, definitions)
    list_summary, read_summary, m0, request_bad_payload_records = (
        decode_requests(records)
    )
    download, completion_record, parameter_bad_payload_records = (
        analyze_parameter_download(records, m0, expected_count)
    )
    heartbeat, heartbeat_bad_payload_records = analyze_heartbeat(
        records, m0, completion_record, heartbeat_limit_us
    )
    relevant_bad_payload_records = (
        request_bad_payload_records
        + parameter_bad_payload_records
        + heartbeat_bad_payload_records
    )
    relevant_bad_payload_count = len(relevant_bad_payload_records)
    integrity["relevant_bad_payload_length_count"] = (
        relevant_bad_payload_count
    )
    integrity["relevant_bad_payload_length_records"] = (
        relevant_bad_payload_records
    )
    for record in relevant_bad_payload_records:
        integrity["anomalies"].append(
            {"kind": "bad_relevant_payload_length", **record}
        )
    integrity["anomaly_count"] = len(integrity["anomalies"])

    parser_valid = bool(
        input_record["stable_during_read"]
        and tlog["exact_eof"]
        and tlog["nonmonotonic_timestamp_count"] == 0
        and integrity["known_bad_crc_count"] == 0
        and integrity["known_bad_payload_length_count"] == 0
        and integrity["unknown_mavlink2_incompatibility_flags_count"] == 0
        and relevant_bad_payload_count == 0
    )
    request_valid = bool(list_summary["eligible_count"] >= 1)
    checks = {
        "input_stable_during_read": bool(input_record["stable_during_read"]),
        "exact_eof": bool(tlog["exact_eof"]),
        "timestamps_monotonic": (
            int(tlog["nonmonotonic_timestamp_count"]) == 0
        ),
        "parser_integrity": parser_valid,
        "eligible_param_request_list_present": request_valid,
        "parameter_download_exact": bool(download["valid"]),
        "heartbeat_within_limit": bool(heartbeat["valid"]),
    }
    valid = all(checks.values())
    return {
        "schema_version": SCHEMA_VERSION,
        "analyzer": "analyze_mission_planner_tlog.py",
        "status": "PASS" if valid else "FAIL",
        "valid": valid,
        "acceptance_scope": (
            f"Mission Planner tlog: GCS 255/190 request to 1/1, exact "
            f"ordered PARAM_VALUE indexes 0..{expected_count - 1} with "
            f"param_count={expected_count}, and source-1/1 HEARTBEAT full-"
            f"window gaps <= {heartbeat_limit_us / 1000.0:g} ms"
        ),
        "measurement_only": True,
        "limitations": [
            "Mission Planner tlog has no explicit TX/RX direction bit; exact source identities are used.",
            "Inbound corrupt/noise bytes rejected before Mission Planner logging are not present in a tlog.",
            "MAVLink2 signature bytes are framed but are not cryptographically verified.",
        ],
        "input": input_record,
        "definitions": {
            "path": str(definitions_path.resolve()),
            "sha256": file_sha256(definitions_path),
            "count": len(definitions),
            "relevant": {
                str(message_id): {
                    "crc_extra": values[0],
                    "minimum_payload_length": values[1],
                    "maximum_payload_length": values[2],
                }
                for message_id, values in sorted(
                    EXPECTED_RELEVANT_DEFINITIONS.items()
                )
            },
        },
        "checks": checks,
        "tlog": tlog,
        "integrity": integrity,
        "requests": {
            "param_request_list": list_summary,
            "param_request_read": read_summary,
        },
        "parameter_download": download,
        "heartbeat": heartbeat,
    }


def expected_count_argument(raw: str) -> int:
    value = int(raw)
    if not 1 <= value <= MAX_EXPECTED_COUNT:
        raise argparse.ArgumentTypeError(
            f"must be in 1..{MAX_EXPECTED_COUNT}"
        )
    return value


def positive_integer(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--expected-count",
        type=expected_count_argument,
        default=DEFAULT_EXPECTED_COUNT,
    )
    parser.add_argument(
        "--heartbeat-limit-us",
        type=positive_integer,
        default=DEFAULT_HEARTBEAT_LIMIT_US,
    )
    parser.add_argument(
        "--definitions",
        type=Path,
        default=DEFAULT_DEFINITIONS,
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    if args.output.exists():
        raise FileExistsError(
            f"refusing to overwrite evidence: {args.output}"
        )
    result = analyze(
        args.input,
        expected_count=args.expected_count,
        heartbeat_limit_us=args.heartbeat_limit_us,
        definitions_path=args.definitions,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False)
        + "\n",
        encoding="utf-8",
    )
    print(
        f"{result['status']} records={result['tlog']['record_count']} "
        f"indexed={result['parameter_download']['unique_index_count']}/"
        f"{args.expected_count} hb_max_ms="
        f"{result['heartbeat']['maximum_gap_ms']} output={args.output}"
    )
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
