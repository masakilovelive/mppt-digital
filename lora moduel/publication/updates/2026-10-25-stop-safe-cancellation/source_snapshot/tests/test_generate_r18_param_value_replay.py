#!/usr/bin/env python3
"""Contract tests for the frozen R18 PARAM_VALUE replay fixture."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import generate_r18_param_value_replay as generator  # noqa: E402


EXPECTED_FILES = {
    "param_value_932.mavlink.bin",
    "param_value_932.index.jsonl",
    "validation.json",
    "manifest.json",
    "SHA256SUMS.txt",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


class FrozenR18ReplayFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.output = Path(cls.temporary.name) / "fixture-a"
        cls.result = generator.generate_fixture(
            generator.DEFAULT_TLOG,
            generator.DEFAULT_ACCEPTANCE_SUMMARY,
            cls.output,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def test_extracts_exact_crc_valid_unsigned_mavlink2_stream(self) -> None:
        stream = (self.output / "param_value_932.mavlink.bin").read_bytes()
        validation = generator.validate_fixture_bytes(stream)

        self.assertEqual(len(stream), 932 * 37)
        self.assertEqual(validation["result"], "PASS")
        self.assertEqual(validation["frame_count"], 932)
        self.assertEqual(validation["valid_crc_count"], 932)
        self.assertEqual(validation["mavlink2_count"], 932)
        self.assertEqual(validation["signed_count"], 0)
        self.assertEqual(validation["first_index"], 0)
        self.assertEqual(validation["last_index"], 931)
        self.assertEqual(validation["unique_index_count"], 932)
        self.assertEqual(validation["unique_param_id_count"], 932)
        self.assertEqual(validation["source"], {"system_id": 1,
                                                 "component_id": 1})
        self.assertEqual(validation["param_count"], 932)
        self.assertEqual(validation["crc_failure_count"], 0)

    def test_provenance_is_pinned_to_accepted_r18_evidence(self) -> None:
        manifest = json.loads(
            (self.output / "manifest.json").read_text(encoding="utf-8")
        )
        source = manifest["source_evidence"]

        self.assertEqual(manifest["result"], "PASS")
        self.assertEqual(source["tlog_sha256"],
                         generator.EXPECTED_TLOG_SHA256)
        self.assertEqual(source["acceptance_summary_sha256"],
                         generator.EXPECTED_ACCEPTANCE_SUMMARY_SHA256)
        self.assertEqual(source["acceptance_result"], "PASS")
        self.assertEqual(source["acceptance_result_detail"],
                         "STRICT_932_AND_HEARTBEAT_SLA_PASS")
        self.assertTrue(source["stable_during_read"])
        self.assertEqual(
            manifest["fixture"]["stream_sha256"],
            sha256(self.output / "param_value_932.mavlink.bin"),
        )
        self.assertEqual(set(path.name for path in self.output.iterdir()),
                         EXPECTED_FILES)

    def test_two_generations_are_byte_deterministic(self) -> None:
        second = Path(self.temporary.name) / "fixture-b"
        generator.generate_fixture(
            generator.DEFAULT_TLOG,
            generator.DEFAULT_ACCEPTANCE_SUMMARY,
            second,
        )

        for name in sorted(EXPECTED_FILES):
            self.assertEqual(
                (self.output / name).read_bytes(),
                (second / name).read_bytes(),
                name,
            )

    def test_index_sidecar_is_complete_and_matches_wire_stream(self) -> None:
        entries = [
            json.loads(line)
            for line in (
                self.output / "param_value_932.index.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]
        stream = (self.output / "param_value_932.mavlink.bin").read_bytes()

        self.assertEqual(len(entries), 932)
        self.assertEqual([entry["param_index"] for entry in entries],
                         list(range(932)))
        for entry in entries:
            start = entry["fixture_offset"]
            end = start + entry["frame_size"]
            self.assertEqual(entry["frame_sha256"],
                             hashlib.sha256(stream[start:end]).hexdigest().upper())

    def test_crc_tamper_is_rejected(self) -> None:
        stream = bytearray(
            (self.output / "param_value_932.mavlink.bin").read_bytes()
        )
        stream[20] ^= 0x01
        with self.assertRaisesRegex(generator.FixtureError, "CRC"):
            generator.validate_fixture_bytes(bytes(stream))

    def test_existing_output_directory_is_not_overwritten(self) -> None:
        with self.assertRaisesRegex(generator.FixtureError,
                                    "already exists"):
            generator.generate_fixture(
                generator.DEFAULT_TLOG,
                generator.DEFAULT_ACCEPTANCE_SUMMARY,
                self.output,
            )


if __name__ == "__main__":
    unittest.main()
