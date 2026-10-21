#!/usr/bin/env python3
"""Regression tests for the parameter-proxy HIL capture analyzer."""

from __future__ import annotations

import base64
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import hil_analyze_param_proxy_capture as analyzer  # noqa: E402


DEFINITIONS = ROOT / "core" / "src" / "mavlink_frame.cpp"


def x25(data: bytes, extra: int) -> int:
    crc = 0xFFFF
    for byte in data + bytes([extra]):
        mixed = byte ^ (crc & 0xFF)
        mixed ^= (mixed << 4) & 0xFF
        crc = ((crc >> 8) ^ (mixed << 8) ^ (mixed << 3) ^ (mixed >> 4)) & 0xFFFF
    return crc


def mavlink1(sequence: int, system_id: int, component_id: int,
             message_id: int, payload: bytes, extra: int) -> bytes:
    body = bytes([len(payload), sequence, system_id, component_id, message_id]) + payload
    return b"\xfe" + body + x25(body, extra).to_bytes(2, "little")


def mavlink2(sequence: int, system_id: int, component_id: int,
             message_id: int, payload: bytes, extra: int) -> bytes:
    header = bytes([
        len(payload), 0, 0, sequence, system_id, component_id,
        message_id & 0xFF, (message_id >> 8) & 0xFF, (message_id >> 16) & 0xFF,
    ])
    return b"\xfd" + header + payload + x25(header + payload, extra).to_bytes(2, "little")


def heartbeat(sequence: int) -> bytes:
    return mavlink2(sequence, 1, 1, 0, bytes(9), 50)


def param_value(sequence: int, index: int, count: int, name: str,
                value: float = 1.0, param_type: int = 9) -> bytes:
    encoded_name = name.encode("ascii")[:16].ljust(16, b"\0")
    payload = struct.pack("<fHH", value, count, index) + encoded_name + bytes([param_type])
    return mavlink2(sequence, 1, 1, 22, payload, 220)


def param_value_v1(sequence: int, index: int, count: int, name: str,
                   value: float = 1.0, param_type: int = 9) -> bytes:
    encoded_name = name.encode("ascii")[:16].ljust(16, b"\0")
    payload = struct.pack("<fHH", value, count, index) + encoded_name + bytes([param_type])
    return mavlink1(sequence, 1, 1, 22, payload, 220)


def control_frame(version: int = 3) -> bytes:
    frame = bytearray(b"VCTD" + bytes([version, 1]) + b"\x0c\x00")
    for value in (1, 2, 650, 300, 64, 0):
        frame.extend(value.to_bytes(2, "little"))
    frame.extend(bytes(10))
    frame.extend(analyzer.crc16_ccitt_false(frame).to_bytes(2, "little"))
    return bytes(frame)


def byte_record(t_us: int, direction: str, payload: bytes) -> dict[str, object]:
    return {
        "kind": "bytes",
        "t_us": t_us,
        "direction": direction,
        "data_b64": base64.b64encode(payload).decode("ascii"),
    }


def write_capture(path: Path, records: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
        encoding="utf-8",
    )


class ParameterProxyCaptureAnalyzerTests(unittest.TestCase):
    def test_decodes_crc_valid_mavlink1_param_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.jsonl"
            records = [
                {
                    "kind": "header", "schema_version": 1,
                    "test_id": "SYNTHETIC-V1", "endpoint": "ground_usb",
                },
                byte_record(100, "rx", param_value_v1(
                    7, 0, 1, "V1_VALUE", 2.25, 6)),
                {"kind": "footer", "completed": True, "duration_us": 200},
            ]
            write_capture(capture, records)
            result = analyzer.analyze([capture], DEFINITIONS, expected_count=1)

        self.assertEqual(result["status"], "PASS_COMPLETE")
        self.assertEqual(result["integrity"]["bad_crc"], 0)
        self.assertEqual(result["param_values"][0]["version"], 1)
        self.assertEqual(result["param_values"][0]["id"], "V1_VALUE")
        self.assertEqual(result["param_values"][0]["value"], 2.25)

    def test_historical_two_segment_download_is_complete(self) -> None:
        captures = [
            ROOT / "runs" / "hil" / "E2E-MAV-PARAM-LIST-PRODUCTION-003"
            / "20260822T163550550Z-ground_usb" / "capture.jsonl",
            ROOT / "runs" / "hil" / "E2E-MAV-PARAM-LIST-PRODUCTION-004"
            / "20260822T163735426Z-ground_usb" / "capture.jsonl",
        ]
        result = analyzer.analyze(captures, DEFINITIONS, expected_count=932)

        self.assertEqual(result["status"], "PASS_COMPLETE")
        self.assertTrue(result["parameter_download"]["complete"])
        self.assertEqual(result["parameter_download"]["unique_index_count"], 932)
        self.assertEqual(result["parameter_download"]["duplicate_frame_count"], 0)
        self.assertEqual(result["parameter_download"]["missing_count"], 0)
        self.assertEqual(result["parameter_download"]["out_of_order_count"], 0)
        self.assertEqual(result["tx_param_request_list"]["count"], 1)
        self.assertFalse(result["captures"][0]["footer_present"])
        self.assertEqual(result["integrity"]["bad_crc"], 0)
        self.assertEqual(result["integrity"]["partial_bytes"], 0)
        self.assertEqual(result["integrity"]["noise_bytes"], 0)
        self.assertEqual(result["integrity"]["control_leak_crc_valid"], 0)
        self.assertEqual(result["heartbeat"]["max_gap_ms"], 3030.627)
        self.assertAlmostEqual(result["heartbeat"]["tail_ms"], 567.035)

    def test_short_historical_capture_is_partial_progress_not_failure(self) -> None:
        capture = (
            ROOT / "runs" / "hil" / "E2E-MAV-PARAM-LIST-PRODUCTION-001"
            / "20260822T161508111Z-ground_usb" / "capture.jsonl"
        )
        result = analyzer.analyze([capture], DEFINITIONS, expected_count=932)

        self.assertEqual(result["status"], "PARTIAL_PROGRESS")
        self.assertFalse(result["parameter_download"]["complete"])
        self.assertGreater(result["parameter_download"]["unique_index_count"], 0)
        self.assertGreater(result["parameter_download"]["missing_count"], 0)
        self.assertEqual(result["integrity"]["bad_crc"], 0)

    def test_reports_decoded_fields_and_all_integrity_classes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.jsonl"
            bad = bytearray(param_value(8, 0, 3, "BAD_CRC"))
            bad[-1] ^= 0x01
            request = mavlink1(40, 255, 190, 21, b"\x01\x01", 159)
            records = [
                {
                    "kind": "header", "schema_version": 1,
                    "test_id": "SYNTHETIC-PROXY", "endpoint": "ground_usb",
                },
                byte_record(100, "rx", heartbeat(1)),
                byte_record(200, "rx", param_value(2, 0, 3, "FIRST", 1.25, 9)),
                byte_record(300, "rx", param_value(3, 2, 3, "THIRD", -2.5, 6)),
                byte_record(400, "rx", param_value(4, 2, 3, "THIRD", -2.5, 6)),
                byte_record(500, "rx", param_value(5, 1, 3, "SECOND", 7.0, 4)),
                byte_record(600, "rx", bytes(bad)),
                byte_record(700, "rx", b"\x99" + control_frame()),
                byte_record(800, "rx", b"\xfd\x19"),
                byte_record(150, "tx", request),
                {"kind": "footer", "completed": True, "duration_us": 1000},
            ]
            write_capture(capture, records)
            result = analyzer.analyze([capture], DEFINITIONS, expected_count=3)

        self.assertEqual(result["status"], "FAIL_INTEGRITY")
        self.assertEqual(result["integrity"]["bad_crc"], 1)
        self.assertEqual(result["integrity"]["partial_bytes"], 2)
        self.assertGreaterEqual(result["integrity"]["noise_bytes"], 33)
        self.assertEqual(result["integrity"]["control_leak_crc_valid"], 1)
        self.assertEqual(result["tx_param_request_list"]["count"], 1)
        self.assertEqual(result["parameter_download"]["duplicate_frame_count"], 1)
        self.assertEqual(result["parameter_download"]["out_of_order_count"], 1)
        decoded = result["param_values"][0]
        self.assertEqual(decoded["index"], 0)
        self.assertEqual(decoded["count"], 3)
        self.assertEqual(decoded["id"], "FIRST")
        self.assertEqual(decoded["value"], 1.25)
        self.assertEqual(decoded["type"], 9)
        self.assertEqual(decoded["sequence"], 2)
        self.assertEqual(decoded["system_id"], 1)
        self.assertEqual(decoded["component_id"], 1)
        self.assertEqual(decoded["t_us"], 200)

    def test_cli_refuses_to_overwrite_evidence(self) -> None:
        capture = (
            ROOT / "runs" / "hil" / "E2E-MAV-PARAM-LIST-PRODUCTION-001"
            / "20260822T161508111Z-ground_usb" / "capture.jsonl"
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            output.write_text("preserve", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable, "-B",
                    str(TOOLS / "hil_analyze_param_proxy_capture.py"),
                    "--input", str(capture), "--output", str(output),
                    "--expected-count", "932",
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(completed.returncode, 2)
            self.assertIn("refusing to overwrite", completed.stderr)
            self.assertEqual(output.read_text(encoding="utf-8"), "preserve")


if __name__ == "__main__":
    unittest.main(verbosity=2)
