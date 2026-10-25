#!/usr/bin/env python3
"""Focused fail-closed tests for R19 Jev/Codex measurement v2."""

from __future__ import annotations

import hashlib
import io
import json
import math
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from tools.jev_advisor.src.record_usage import (  # noqa: E402
    MeasurementError,
    calculate_measurement,
    normalize_openai_usage,
    record_measurement,
    main as record_usage_main,
)


def raw_measurement(**changes: object) -> dict[str, object]:
    result: dict[str, object] = {
        "measurement_schema": "jev-token-eval-2",
        "run_id": "R19-HOST-001",
        "issue_id": "R19-GRANT-HANDOFF-001",
        "mode": "jev_hybrid",
        "source_hash": "c" * 64,
        "codex_model": "test-model",
        "reasoning_effort": "medium",
        "codex_called": True,
        "jev_called": True,
        "input_tokens": 100,
        "cached_input_tokens": 20,
        "output_tokens": 30,
        "total_tokens": 150,
        "jev_input_tokens": 40,
        "jev_output_tokens": 2,
        "action_id": "CODE_REVIEW_REQUIRED",
        "confidence": 0.91,
        "route_correct": True,
        "accepted_fix": False,
        "human_adjudication_id": "review-001",
        "adjudicated_at": "2026-09-23T09:15:00+09:00",
        "retry_count": 0,
        "safety_violation": False,
        "elapsed_seconds": 12.5,
        "jev_cost_usd": 0.0000016,
        "usage_source": "api_exact",
        "jev_generation_id": "eval_123",
        "measured_at": "2026-09-23T09:00:00+09:00",
    }
    result.update(changes)
    return result


def rate_card() -> dict[str, object]:
    return {
        "rate_card_version": "test-v2",
        "description": "Unit-test rates only.",
        "source_url": "https://example.test/rates/test-v2",
        "retrieved_at": "2026-09-22T23:59:59Z",
        "models": {
            "test-model": {
                "input_per_million": 10.0,
                "cached_input_per_million": 2.0,
                "output_per_million": 30.0,
            }
        },
    }


class MeasurementV2Tests(unittest.TestCase):
    def test_normalizes_raw_openai_usage_without_double_counting_cache(self) -> None:
        normalized = normalize_openai_usage(
            {
                "input_tokens": 100,
                "input_tokens_details": {"cached_tokens": 20},
                "output_tokens": 30,
                "total_tokens": 130,
            }
        )
        self.assertEqual(
            {
                "input_tokens": 80,
                "cached_input_tokens": 20,
                "output_tokens": 30,
                "total_tokens": 130,
            },
            normalized,
        )
        with self.assertRaises(MeasurementError):
            normalize_openai_usage(
                {
                    "input_tokens": 10,
                    "input_tokens_details": {"cached_tokens": 11},
                    "output_tokens": 1,
                    "total_tokens": 11,
                }
            )

    def test_calculates_from_normalized_tokens_and_binds_rate_provenance(self) -> None:
        rates = rate_card()
        result = calculate_measurement(raw_measurement(), rates)
        canonical = json.dumps(
            rates,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        self.assertAlmostEqual(0.00194, result["codex_credits"])
        self.assertEqual("test-v2", result["rate_card_version"])
        self.assertEqual(
            hashlib.sha256(canonical).hexdigest(), result["rate_card_hash"]
        )
        self.assertEqual(
            "https://example.test/rates/test-v2", result["rate_card_source"]
        )
        self.assertEqual(
            "2026-09-22T23:59:59Z", result["rate_card_retrieved_at"]
        )

    def test_fixed_local_run_supports_null_advisory_and_judgment_fields(self) -> None:
        raw = raw_measurement(
            codex_called=False,
            jev_called=False,
            input_tokens=0,
            cached_input_tokens=0,
            output_tokens=0,
            total_tokens=0,
            jev_input_tokens=0,
            jev_output_tokens=0,
            action_id=None,
            confidence=None,
            route_correct=None,
            accepted_fix=None,
            human_adjudication_id=None,
            adjudicated_at=None,
            jev_cost_usd=0.0,
            usage_source="estimated",
            jev_generation_id=None,
        )
        result = calculate_measurement(raw, rate_card())
        self.assertEqual(0.0, result["codex_credits"])

    def test_attempted_jev_fallback_does_not_invent_a_result_or_receipt(self) -> None:
        raw = raw_measurement(
            action_id=None,
            confidence=None,
            route_correct=None,
            accepted_fix=None,
            human_adjudication_id=None,
            adjudicated_at=None,
            jev_input_tokens=0,
            jev_output_tokens=0,
            jev_cost_usd=0.0,
            usage_source="estimated",
            jev_generation_id=None,
        )
        result = calculate_measurement(raw, rate_card())
        self.assertTrue(result["jev_called"])
        self.assertIsNone(result["action_id"])
        self.assertIsNone(result["confidence"])
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "fallback.jsonl"
            record_measurement(destination, result)
            saved = json.loads(destination.read_text(encoding="utf-8"))
            self.assertIsNone(saved["jev_generation_id"])

    def test_rejects_unproven_exact_usage_and_quality_labels(self) -> None:
        with self.assertRaisesRegex(MeasurementError, "jev_generation_id"):
            calculate_measurement(
                raw_measurement(jev_generation_id=None), rate_card()
            )
        with self.assertRaisesRegex(MeasurementError, "human adjudication"):
            calculate_measurement(
                raw_measurement(human_adjudication_id=None), rate_card()
            )

    def test_rejects_unknown_fields_non_rfc3339_and_nonfinite_values(self) -> None:
        with self.assertRaisesRegex(MeasurementError, "unknown measurement fields"):
            calculate_measurement(raw_measurement(unbounded_note="no"), rate_card())
        with self.assertRaisesRegex(MeasurementError, "RFC 3339"):
            calculate_measurement(
                raw_measurement(measured_at="2026-09-23"), rate_card()
            )
        with self.assertRaisesRegex(MeasurementError, "finite"):
            calculate_measurement(
                raw_measurement(jev_cost_usd=math.nan), rate_card()
            )

    def test_record_measurement_revalidates_before_append(self) -> None:
        result = calculate_measurement(raw_measurement(), rate_card())
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "measurement.jsonl"
            record_measurement(destination, result)
            self.assertEqual(
                result,
                json.loads(destination.read_text(encoding="utf-8").strip()),
            )
            invalid = dict(result)
            invalid["codex_credits"] = math.inf
            with self.assertRaises(MeasurementError):
                record_measurement(destination, invalid)
            self.assertEqual(1, len(destination.read_text(encoding="utf-8").splitlines()))

    def test_schema_and_unconfigured_template_expose_v2_provenance(self) -> None:
        schema = json.loads(
            (
                REPO
                / "tools"
                / "jev_advisor"
                / "schemas"
                / "token_measurement.schema.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(
            "jev-token-eval-2", schema["properties"]["measurement_schema"]["const"]
        )
        for field in (
            "jev_called",
            "human_adjudication_id",
            "adjudicated_at",
            "jev_generation_id",
            "rate_card_hash",
            "rate_card_source",
            "rate_card_retrieved_at",
        ):
            self.assertIn(field, schema["required"])
        template = json.loads(
            (
                REPO
                / "tools"
                / "jev_advisor"
                / "policies"
                / "codex_rate_cards.json"
            ).read_text(encoding="utf-8")
        )
        self.assertIn("source_url", template)
        self.assertIn("retrieved_at", template)
        with self.assertRaises(MeasurementError):
            calculate_measurement(raw_measurement(), template)

    def test_cli_validates_prices_and_appends_one_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw_path = root / "raw.json"
            rates_path = root / "rates.json"
            output_path = root / "token_usage.jsonl"
            raw_path.write_text(json.dumps(raw_measurement()), encoding="utf-8")
            rates_path.write_text(json.dumps(rate_card()), encoding="utf-8")
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                exit_code = record_usage_main(
                    [
                        "--measurement",
                        str(raw_path),
                        "--rate-card",
                        str(rates_path),
                        "--output",
                        str(output_path),
                    ]
                )
            self.assertEqual(0, exit_code)
            self.assertIn("JEV_TOKEN_MEASUREMENT RECORDED", stdout.getvalue())
            saved = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual("test-v2", saved["rate_card_version"])


if __name__ == "__main__":
    unittest.main()
