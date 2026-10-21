#!/usr/bin/env python3
"""Regression tests for the Mission Planner telemetry-log analyzer."""

from __future__ import annotations

import hashlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import analyze_mission_planner_tlog as analyzer  # noqa: E402


BASE_US = 1_800_000_000_000_000


def x25(data: bytes, extra: int) -> int:
    crc = 0xFFFF
    for byte in data + bytes([extra]):
        mixed = byte ^ (crc & 0xFF)
        mixed ^= (mixed << 4) & 0xFF
        crc = (
            (crc >> 8) ^ (mixed << 8) ^ (mixed << 3) ^ (mixed >> 4)
        ) & 0xFFFF
    return crc


def mavlink1(
    sequence: int,
    system_id: int,
    component_id: int,
    message_id: int,
    payload: bytes,
    extra: int,
) -> bytes:
    body = bytes(
        [len(payload), sequence, system_id, component_id, message_id]
    ) + payload
    return b"\xfe" + body + x25(body, extra).to_bytes(2, "little")


def mavlink2(
    sequence: int,
    system_id: int,
    component_id: int,
    message_id: int,
    payload: bytes,
    extra: int,
    *,
    signature: bytes | None = None,
) -> bytes:
    incompatibility_flags = 1 if signature is not None else 0
    header = bytes(
        [
            len(payload),
            incompatibility_flags,
            0,
            sequence,
            system_id,
            component_id,
            message_id & 0xFF,
            (message_id >> 8) & 0xFF,
            (message_id >> 16) & 0xFF,
        ]
    )
    frame = (
        b"\xfd"
        + header
        + payload
        + x25(header + payload, extra).to_bytes(2, "little")
    )
    if signature is not None:
        if len(signature) != 13:
            raise ValueError("a MAVLink2 signature is exactly 13 bytes")
        frame += signature
    return frame


def heartbeat(
    sequence: int,
    *,
    system_id: int = 1,
    component_id: int = 1,
    v1: bool = False,
) -> bytes:
    payload = struct.pack("<IBBBBB", 0, 10, 3, 0, 4, 3)
    builder = mavlink1 if v1 else mavlink2
    return builder(sequence, system_id, component_id, 0, payload, 50)


def request_list(sequence: int, *, v1: bool = False) -> bytes:
    builder = mavlink1 if v1 else mavlink2
    return builder(sequence, 255, 190, 21, b"\x01\x01", 159)


def request_read_truncated(sequence: int, index: int) -> bytes:
    # Mission Planner's MAVLink2 generator removes the all-zero param_id tail.
    payload = struct.pack("<hBB", index, 1, 1)
    return mavlink2(sequence, 255, 190, 20, payload, 214)


def param_value(
    sequence: int,
    index: int,
    count: int,
    *,
    system_id: int = 1,
    component_id: int = 1,
    v1: bool = False,
) -> bytes:
    name = f"P{index:04d}".encode("ascii").ljust(16, b"\0")
    payload = struct.pack("<fHH", float(index), count, index) + name + b"\x06"
    builder = mavlink1 if v1 else mavlink2
    return builder(
        sequence, system_id, component_id, 22, payload, 220
    )


def timestamped(timestamp_us: int, frame: bytes) -> bytes:
    return timestamp_us.to_bytes(8, "big") + frame


def write_tlog(path: Path, records: list[tuple[int, bytes]]) -> None:
    path.write_bytes(b"".join(timestamped(t, frame) for t, frame in records))


def compact_pass_records(expected_count: int = 4) -> list[tuple[int, bytes]]:
    return [
        (BASE_US, request_list(1)),
        (BASE_US + 100_000, param_value(2, 0, expected_count)),
        (BASE_US + 500_000, heartbeat(3)),
        (BASE_US + 700_000, param_value(4, 1, expected_count)),
        (BASE_US + 800_000, request_read_truncated(5, 2)),
        (BASE_US + 1_000_000, heartbeat(6, system_id=255,
                                      component_id=190)),
        (BASE_US + 1_500_000, param_value(7, 2, expected_count)),
        (BASE_US + 2_000_000, heartbeat(8)),
        (BASE_US + 2_200_000, param_value(9, 3, expected_count)),
    ]


class MissionPlannerTlogAnalyzerTests(unittest.TestCase):
    def analyze_records(
        self,
        records: list[tuple[int, bytes]],
        *,
        expected_count: int = 4,
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.tlog"
            write_tlog(path, records)
            return analyzer.analyze(path, expected_count=expected_count)

    def test_passes_exact_932_download_and_preserves_truncated_read(self) -> None:
        events: list[tuple[int, bytes]] = [(BASE_US, request_list(1))]
        sequence = 2
        for index in range(932):
            events.append(
                (
                    BASE_US + 10_000 + index * 3_000,
                    param_value(sequence, index, 932),
                )
            )
            sequence = (sequence + 1) & 0xFF
        events.extend(
            [
                (BASE_US + 400_000, heartbeat(20)),
                (BASE_US + 800_000, request_read_truncated(21, 700)),
                (BASE_US + 1_400_000, heartbeat(22)),
                (BASE_US + 2_400_000, heartbeat(23)),
            ]
        )
        result = self.analyze_records(sorted(events), expected_count=932)

        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["valid"])
        self.assertEqual(result["tlog"]["record_count"], len(events))
        self.assertTrue(result["tlog"]["exact_eof"])
        self.assertEqual(result["tlog"]["nonmonotonic_timestamp_count"], 0)
        self.assertEqual(result["integrity"]["known_bad_crc_count"], 0)
        self.assertEqual(result["requests"]["param_request_list"]["count"], 1)
        reads = result["requests"]["param_request_read"]
        self.assertEqual(reads["count"], 1)
        self.assertEqual(reads["payload_length_counts"], {"4": 1})
        self.assertEqual(reads["unique_requested_indexes"], 1)
        self.assertEqual(reads["first_index"], 700)
        download = result["parameter_download"]
        self.assertEqual(download["indexed_frame_count"], 932)
        self.assertEqual(download["unique_index_count"], 932)
        self.assertEqual(download["missing_count"], 0)
        self.assertEqual(download["duplicate_frame_count"], 0)
        self.assertEqual(download["out_of_order_count"], 0)
        self.assertEqual(download["source"], {"system_id": 1, "component_id": 1})
        heartbeat_result = result["heartbeat"]
        self.assertTrue(heartbeat_result["valid"])
        self.assertEqual(heartbeat_result["source"],
                         {"system_id": 1, "component_id": 1})
        self.assertEqual(heartbeat_result["count"], 3)
        self.assertLessEqual(heartbeat_result["maximum_gap_ms"], 2500.0)

    def test_supports_mavlink1_records_and_signed_mavlink2_framing(self) -> None:
        records = [
            (BASE_US, request_list(1, v1=True)),
            (BASE_US + 100_000, param_value(2, 0, 2, v1=True)),
            (BASE_US + 200_000, heartbeat(3, v1=True)),
            (
                BASE_US + 300_000,
                mavlink2(
                    4,
                    255,
                    190,
                    253,
                    b"\x06signed-status",
                    83,
                    signature=bytes(range(13)),
                ),
            ),
            (BASE_US + 1_200_000, heartbeat(5, v1=True)),
            (BASE_US + 1_300_000, param_value(6, 1, 2, v1=True)),
        ]
        result = self.analyze_records(records, expected_count=2)

        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["tlog"]["mavlink1_frame_count"], 5)
        self.assertEqual(result["tlog"]["mavlink2_frame_count"], 1)
        self.assertEqual(result["tlog"]["signed_mavlink2_frame_count"], 1)
        self.assertFalse(result["integrity"]["signatures_cryptographically_verified"])
        self.assertEqual(result["integrity"]["known_bad_crc_count"], 0)

    def test_reports_missing_duplicate_order_count_and_wrong_source(self) -> None:
        records = [
            (BASE_US, request_list(1)),
            (BASE_US + 100_000, heartbeat(2)),
            (BASE_US + 200_000, param_value(3, 0, 4)),
            (BASE_US + 300_000, param_value(4, 2, 4)),
            (BASE_US + 400_000, param_value(5, 1, 4)),
            (BASE_US + 500_000, param_value(6, 2, 4)),
            (
                BASE_US + 600_000,
                param_value(7, 3, 4, component_id=2),
            ),
            (BASE_US + 1_100_000, heartbeat(8)),
        ]
        result = self.analyze_records(records)

        self.assertEqual(result["status"], "FAIL")
        download = result["parameter_download"]
        self.assertEqual(download["missing_indexes"], [3])
        self.assertEqual(download["duplicate_frame_count"], 1)
        self.assertGreater(download["out_of_order_count"], 0)
        self.assertEqual(download["wrong_source_frame_count"], 1)

    def test_parameter_accounting_stops_at_first_expected_last_index(self) -> None:
        records = compact_pass_records()
        records.extend(
            [
                (BASE_US + 2_300_000, param_value(10, 0, 4)),
                (BASE_US + 2_400_000, param_value(11, 1, 4)),
            ]
        )
        result = self.analyze_records(sorted(records))

        self.assertEqual(result["status"], "PASS")
        download = result["parameter_download"]
        self.assertEqual(download["indexed_frame_count"], 4)
        self.assertEqual(download["unique_index_count"], 4)
        self.assertEqual(download["duplicate_frame_count"], 0)
        self.assertEqual(download["last_index"], 3)

    def test_rejects_bad_relevant_crc_without_counting_the_frame(self) -> None:
        records = compact_pass_records()
        corrupt = bytearray(records[-1][1])
        corrupt[-1] ^= 0x80
        records[-1] = (records[-1][0], bytes(corrupt))
        result = self.analyze_records(records)

        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["integrity"]["known_bad_crc_count"], 1)
        self.assertEqual(result["integrity"]["relevant_bad_crc_count"], 1)
        self.assertEqual(result["parameter_download"]["missing_indexes"], [3])

    def test_len4_request_read_is_valid_but_len3_is_a_semantic_anomaly(self) -> None:
        records = compact_pass_records()
        invalid_payload = struct.pack("<hB", 2, 1)
        records.append(
            (
                BASE_US + 900_000,
                mavlink2(40, 255, 190, 20, invalid_payload, 214),
            )
        )
        result = self.analyze_records(sorted(records))

        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(
            result["integrity"]["relevant_bad_payload_length_count"], 1
        )
        bad = result["integrity"]["relevant_bad_payload_length_records"][0]
        self.assertEqual(bad["message_id"], 20)
        self.assertEqual(bad["payload_length"], 3)
        self.assertEqual(
            result["requests"]["param_request_read"]["payload_length_counts"],
            {"4": 1},
        )

    def test_vehicle_heartbeat_gap_is_not_hidden_by_gcs_heartbeats(self) -> None:
        records = [
            (BASE_US, request_list(1)),
            (BASE_US, heartbeat(2)),
            (BASE_US + 100_000, param_value(3, 0, 2)),
        ]
        for ordinal, offset in enumerate(range(500_000, 3_000_000, 500_000), 4):
            records.append(
                (BASE_US + offset, heartbeat(
                    ordinal, system_id=255, component_id=190))
            )
        records.extend(
            [
                (BASE_US + 3_000_000, heartbeat(20)),
                (BASE_US + 3_100_000, param_value(21, 1, 2)),
            ]
        )
        result = self.analyze_records(sorted(records), expected_count=2)

        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["heartbeat"]["count"], 2)
        self.assertEqual(result["heartbeat"]["maximum_gap_ms"], 3000.0)
        self.assertEqual(result["heartbeat"]["exceedance_count"], 1)

    def test_heartbeat_limit_is_inclusive_at_integer_microsecond_precision(self) -> None:
        passing = [
            (BASE_US, request_list(1)),
            (BASE_US, heartbeat(2)),
            (BASE_US + 2_500_000, heartbeat(3)),
            (BASE_US + 2_500_000, param_value(4, 0, 1)),
        ]
        failing = list(passing)
        failing[-2] = (BASE_US + 2_500_001, heartbeat(3))
        failing[-1] = (BASE_US + 2_500_001, param_value(4, 0, 1))

        pass_result = self.analyze_records(passing, expected_count=1)
        fail_result = self.analyze_records(failing, expected_count=1)

        self.assertEqual(pass_result["heartbeat"]["maximum_gap_us"], 2_500_000)
        self.assertTrue(pass_result["heartbeat"]["valid"])
        self.assertEqual(fail_result["heartbeat"]["maximum_gap_us"], 2_500_001)
        self.assertFalse(fail_result["heartbeat"]["valid"])

    def test_fails_closed_on_nonmonotonic_timestamp_and_truncated_tail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            nonmonotonic = Path(temporary) / "nonmonotonic.tlog"
            write_tlog(
                nonmonotonic,
                [
                    (BASE_US + 1, request_list(1)),
                    (BASE_US, heartbeat(2)),
                ],
            )
            result = analyzer.analyze(nonmonotonic, expected_count=1)
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(result["tlog"]["nonmonotonic_timestamp_count"], 1)

            truncated = Path(temporary) / "truncated.tlog"
            truncated.write_bytes(
                timestamped(BASE_US, request_list(1)) + b"\x00\x01\x02"
            )
            result = analyzer.analyze(truncated, expected_count=1)
            self.assertEqual(result["status"], "FAIL")
            self.assertFalse(result["tlog"]["exact_eof"])
            self.assertEqual(result["integrity"]["truncated_timestamp_bytes"], 3)

    def test_fails_closed_on_bad_magic_and_truncated_signed_frame(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bad_magic = Path(temporary) / "bad-magic.tlog"
            bad_magic.write_bytes(BASE_US.to_bytes(8, "big") + b"\x00junk")
            result = analyzer.analyze(bad_magic, expected_count=1)
            self.assertEqual(result["integrity"]["bad_magic_count"], 1)
            self.assertFalse(result["tlog"]["exact_eof"])

            signed = mavlink2(
                1, 255, 190, 253, b"\x06x", 83,
                signature=bytes(range(13)),
            )
            truncated = Path(temporary) / "truncated-signed.tlog"
            truncated.write_bytes(timestamped(BASE_US, signed[:-1]))
            result = analyzer.analyze(truncated, expected_count=1)
            self.assertEqual(result["integrity"]["truncated_frame_count"], 1)
            self.assertFalse(result["tlog"]["exact_eof"])

    def test_cli_refuses_overwrite_and_uses_pass_fail_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.tlog"
            write_tlog(source, compact_pass_records())
            output = Path(temporary) / "summary.json"
            command = [
                sys.executable,
                "-B",
                str(TOOLS / "analyze_mission_planner_tlog.py"),
                "--input",
                str(source),
                "--output",
                str(output),
                "--expected-count",
                "4",
            ]
            passed = subprocess.run(
                command, text=True, capture_output=True, check=False
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("PASS", passed.stdout)
            before = output.read_bytes()
            refused = subprocess.run(
                command, text=True, capture_output=True, check=False
            )
            self.assertEqual(refused.returncode, 2)
            self.assertIn("refusing to overwrite", refused.stderr)
            self.assertEqual(output.read_bytes(), before)

            failed_source = Path(temporary) / "failed.tlog"
            write_tlog(failed_source, compact_pass_records()[:-1])
            failed_output = Path(temporary) / "failed-summary.json"
            failed = subprocess.run(
                command[:4]
                + [str(failed_source), "--output", str(failed_output),
                   "--expected-count", "4"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(failed.returncode, 1, failed.stderr)
            self.assertIn("FAIL", failed.stdout)

    def test_input_hash_is_the_exact_analyzed_byte_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.tlog"
            write_tlog(path, compact_pass_records())
            expected = hashlib.sha256(path.read_bytes()).hexdigest().upper()
            result = analyzer.analyze(path, expected_count=4)

        self.assertEqual(result["input"]["sha256"], expected)
        self.assertEqual(result["input"]["size_bytes"],
                         result["tlog"]["bytes_consumed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
