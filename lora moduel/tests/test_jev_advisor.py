#!/usr/bin/env python3
"""Fail-closed Phase-A tests for the R19 Jev diagnostic advisor."""

from __future__ import annotations

import json
import io
import hashlib
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from tools.jev_advisor.src.build_codex_context import build_context_package
from tools.jev_advisor.src.collect_run import (
    normalize_r19_offline_replay,
    normalize_run,
    prepare_r19_offline_replay_input,
)
from tools.jev_advisor.src.evaluate_run import evaluate_run
from tools.jev_advisor.src.jev_client import JEV_EVALUATE_ENDPOINT, JevGatewayClient
from tools.jev_advisor.src.policy_gate import (
    ACTION_IDS,
    InputValidationError,
    PolicyValidationError,
    compute_source_hash,
    evaluate_fixed_policy,
    load_action_policy,
    validate_decision_input,
    validate_action_policy,
    verify_source_manifest,
)
from tools.jev_advisor.src.record_usage import (
    MeasurementError,
    calculate_measurement,
    normalize_openai_usage,
    record_measurement,
)
from tools.jev_advisor.src.run_shadow import main as run_shadow_main
from tools.jev_advisor.src.run_shadow import run_shadow


POLICY = REPO / "tools" / "jev_advisor" / "policies" / "r19_actions.json"
SPEC_SHA256 = "A3DC9DA596DD14581781EB5EF05E7575672C90BC5982ADE76AE2037B1DAAC66E"
SOURCE_MANIFEST = [
    {
        "path": "Jev_Integration_and_Token_Measurement_Spec_R19.md",
        "sha256": SPEC_SHA256,
    }
]


def accepted_input(**changes: object) -> dict[str, object]:
    result: dict[str, object] = {
        "schema_version": "r19-jev-input-2",
        "run_id": "R19-HIL-001",
        "source_manifest": SOURCE_MANIFEST,
        "source_hash": compute_source_hash(SOURCE_MANIFEST),
        "test_scope": "hil",
        "evidence_scope": "hil_physical",
        "host_tests_passed": 250,
        "host_tests_failed": 0,
        "failed_test_ids": [],
        "sanitizer_errors": 0,
        "expected_params": 932,
        "received_params": 932,
        "first_missing_index": None,
        "completion_ms": 29999.0,
        "heartbeat_first_ms": 1000.0,
        "heartbeat_max_ms": 2500.0,
        "heartbeat_post_ms": 900.0,
        "heartbeat_count": 30,
        "missing_params": 0,
        "duplicate_params": 0,
        "out_of_order_params": 0,
        "crc_errors": 0,
        "parser_errors": 0,
        "partial_frames": 0,
        "control_leakage": 0,
        "retry_identity_status": "proven",
        "standard_grant_handoff_status": "proven",
        "direction_guard_status": "proven",
        "physical_tail_status": "proven",
        "vcta_physical_drain_status": "proven",
        "live_flash_authorized": False,
        "hardware_operation_requested": False,
        "communication_parameter_change_requested": False,
        "acceptance_relaxation_requested": False,
    }
    result.update(changes)
    return result


class PolicyGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = load_action_policy(POLICY)

    def test_exact_fixed_acceptance_bypasses_jev(self) -> None:
        called = 0

        def forbidden_client(_: dict[str, object]) -> dict[str, object]:
            nonlocal called
            called += 1
            raise AssertionError("Jev must not override a complete fixed result")

        result = evaluate_run(accepted_input(), self.policy, forbidden_client)
        self.assertEqual("PASS_FIXED", result["verdict"])
        self.assertFalse(result["jev_called"])
        self.assertEqual(0, called)

    def test_safety_condition_preempts_confidence_and_api(self) -> None:
        result = evaluate_run(
            accepted_input(hardware_operation_requested=True),
            self.policy,
            lambda _: self.fail("Jev was called after a safety stop"),
        )
        self.assertEqual("STOP", result["verdict"])
        self.assertEqual("STOP_SAFETY_CONDITION", result["action_id"])
        self.assertFalse(result["jev_called"])

    def test_fixed_failure_cannot_be_changed_to_pass(self) -> None:
        result = evaluate_run(
            accepted_input(crc_errors=1),
            self.policy,
            lambda _: self.fail("Jev was called for a deterministic CRC failure"),
        )
        self.assertEqual("FAIL_FIXED", result["verdict"])
        self.assertEqual("CODE_REVIEW_REQUIRED", result["action_id"])
        self.assertFalse(result["jev_called"])

    def test_known_missing_physical_tail_routes_without_api(self) -> None:
        result = evaluate_fixed_policy(
            accepted_input(physical_tail_status="unknown"), self.policy
        )
        self.assertEqual("EVIDENCE_REQUIRED", result["verdict"])
        self.assertEqual("INSPECT_FINAL_VCB1_TAIL", result["action_id"])

        disproven = evaluate_fixed_policy(
            accepted_input(retry_identity_status="disproven"), self.policy
        )
        self.assertEqual("FAIL_FIXED", disproven["verdict"])
        self.assertEqual("RUN_FOCUSED_GRANT_TEST", disproven["action_id"])

    def test_ambiguous_host_failure_uses_one_bounded_choice(self) -> None:
        seen: list[dict[str, object]] = []

        def client(payload: dict[str, object]) -> dict[str, object]:
            seen.append(payload)
            return {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "RUN_FOCUSED_GRANT_TEST",
                        "probabilities": {
                            "RUN_FOCUSED_GRANT_TEST": 0.94,
                            "COLLECT_MORE_EVIDENCE": 0.06,
                            "RUN_DIRECTION_GUARD_TEST": 0.0,
                            "INSPECT_FINAL_VCB1_TAIL": 0.0,
                            "INSPECT_VCTA_PHYSICAL_DRAIN": 0.0,
                            "CODE_REVIEW_REQUIRED": 0.0,
                            "HUMAN_REVIEW_REQUIRED": 0.0,
                            "STOP_SAFETY_CONDITION": 0.0,
                        },
                    }
                },
                "usage": {"inputTokens": 91, "outputTokens": 4},
                "providerMetadata": {
                    "gateway": {"cost": "0.00000364", "generationId": "gen_test"}
                },
            }

        result = evaluate_run(
            accepted_input(
                host_tests_failed=1,
                host_tests_passed=249,
                failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
            ),
            self.policy,
            client,
        )
        self.assertEqual(1, len(seen))
        self.assertEqual("typesafe-ai/jev", seen[0]["model"])
        self.assertEqual(
            {"zeroDataRetention": True, "only": ["typesafe-ai"]},
            seen[0]["providerOptions"]["gateway"],  # type: ignore[index]
        )
        self.assertEqual("RUN_FOCUSED_GRANT_TEST", result["action_id"])
        self.assertEqual("SHADOW_AUTO_ELIGIBLE", result["execution_class"])
        self.assertAlmostEqual(0.94, result["confidence"])
        self.assertTrue(result["jev_called"])
        self.assertEqual("r19-jev-final-action-1", result["schema_version"])
        self.assertEqual("r19-actions-2", result["policy_version"])
        self.assertEqual(64, len(result["request_hash"]))
        self.assertEqual(set(result["probabilities"]), set(ACTION_IDS))

    def test_low_confidence_or_api_failure_collects_more_evidence(self) -> None:
        low = evaluate_run(
            accepted_input(
                host_tests_failed=1,
                host_tests_passed=249,
                failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
            ),
            self.policy,
            lambda _: {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "CODE_REVIEW_REQUIRED",
                        "probabilities": {
                            "RUN_FOCUSED_GRANT_TEST": 0.0,
                            "RUN_DIRECTION_GUARD_TEST": 0.0,
                            "INSPECT_FINAL_VCB1_TAIL": 0.0,
                            "INSPECT_VCTA_PHYSICAL_DRAIN": 0.0,
                            "COLLECT_MORE_EVIDENCE": 0.39,
                            "CODE_REVIEW_REQUIRED": 0.61,
                            "HUMAN_REVIEW_REQUIRED": 0.0,
                            "STOP_SAFETY_CONDITION": 0.0,
                        },
                    }
                },
                "usage": {"inputTokens": 80, "outputTokens": 3},
                "providerMetadata": {
                    "gateway": {
                        "cost": "0.00000332",
                        "generationId": "gen_low",
                    }
                },
            },
        )
        self.assertEqual("COLLECT_MORE_EVIDENCE", low["action_id"])
        self.assertEqual("INSUFFICIENT_CONFIDENCE", low["execution_class"])

        unavailable = evaluate_run(
            accepted_input(
                host_tests_failed=1,
                host_tests_passed=249,
                failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
            ),
            self.policy,
            lambda _: (_ for _ in ()).throw(TimeoutError("offline")),
        )
        self.assertEqual("COLLECT_MORE_EVIDENCE", unavailable["action_id"])
        self.assertEqual("API_FALLBACK", unavailable["execution_class"])

        invalid = evaluate_run(
            accepted_input(
                host_tests_failed=1,
                host_tests_passed=249,
                failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
            ),
            self.policy,
            lambda _: {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "NOT_ALLOWED",
                        "probabilities": {"NOT_ALLOWED": 1.0},
                    }
                },
            },
        )
        self.assertEqual("COLLECT_MORE_EVIDENCE", invalid["action_id"])
        self.assertEqual("API_FALLBACK", invalid["execution_class"])

        incomplete = evaluate_run(
            accepted_input(
                host_tests_failed=1,
                host_tests_passed=249,
                failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
            ),
            self.policy,
            lambda _: {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "RUN_FOCUSED_GRANT_TEST",
                        "probabilities": {"RUN_FOCUSED_GRANT_TEST": 1.0},
                    }
                },
            },
        )
        self.assertEqual("COLLECT_MORE_EVIDENCE", incomplete["action_id"])
        self.assertEqual("API_FALLBACK", incomplete["execution_class"])

    def test_malformed_probability_distribution_or_cost_falls_back(self) -> None:
        ambiguous = accepted_input(
            host_tests_failed=1,
            host_tests_passed=249,
            failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
        )

        def response(cost: object, total: float) -> dict[str, object]:
            return {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "RUN_FOCUSED_GRANT_TEST",
                        "probabilities": {
                            "RUN_FOCUSED_GRANT_TEST": total,
                            "RUN_DIRECTION_GUARD_TEST": 0.0,
                            "INSPECT_FINAL_VCB1_TAIL": 0.0,
                            "INSPECT_VCTA_PHYSICAL_DRAIN": 0.0,
                            "COLLECT_MORE_EVIDENCE": 0.0,
                            "CODE_REVIEW_REQUIRED": 0.0,
                            "HUMAN_REVIEW_REQUIRED": 0.0,
                            "STOP_SAFETY_CONDITION": 0.0,
                        },
                    }
                },
                "usage": {"inputTokens": 80, "outputTokens": 3},
                "providerMetadata": {
                    "gateway": {"cost": cost, "generationId": "gen_bad"}
                },
            }

        bad_sum = evaluate_run(
            ambiguous, self.policy, lambda _: response("0.00000332", 0.98)
        )
        self.assertEqual("API_FALLBACK", bad_sum["execution_class"])
        bad_cost = evaluate_run(
            ambiguous, self.policy, lambda _: response("NaN", 1.0)
        )
        self.assertEqual("API_FALLBACK", bad_cost["execution_class"])

    def test_confidence_boundaries_are_inclusive_at_point_70_and_point_90(self) -> None:
        ambiguous = accepted_input(
            host_tests_failed=1,
            host_tests_passed=249,
            failed_test_ids=["high_speed_tdd_coordinator.grant_handoff"],
        )

        def response(confidence: float, generation: str) -> dict[str, object]:
            return {
                "model": "typesafe-ai/jev",
                "answers": {
                    "route": {
                        "type": "choice",
                        "choice": "RUN_FOCUSED_GRANT_TEST",
                        "probabilities": {
                            "RUN_FOCUSED_GRANT_TEST": confidence,
                            "RUN_DIRECTION_GUARD_TEST": 0.0,
                            "INSPECT_FINAL_VCB1_TAIL": 0.0,
                            "INSPECT_VCTA_PHYSICAL_DRAIN": 0.0,
                            "COLLECT_MORE_EVIDENCE": 1.0 - confidence,
                            "CODE_REVIEW_REQUIRED": 0.0,
                            "HUMAN_REVIEW_REQUIRED": 0.0,
                            "STOP_SAFETY_CONDITION": 0.0,
                        },
                    }
                },
                "usage": {"inputTokens": 80, "outputTokens": 3},
                "providerMetadata": {
                    "gateway": {"cost": "0.00000332", "generationId": generation}
                },
            }

        review = evaluate_run(
            ambiguous, self.policy, lambda _: response(0.70, "gen_70")
        )
        automatic = evaluate_run(
            ambiguous, self.policy, lambda _: response(0.90, "gen_90")
        )
        self.assertEqual("REVIEW_REQUIRED", review["execution_class"])
        self.assertEqual("SHADOW_AUTO_ELIGIBLE", automatic["execution_class"])

    def test_invalid_or_incomplete_input_fails_closed(self) -> None:
        item = accepted_input()
        del item["completion_ms"]
        with self.assertRaises(InputValidationError):
            validate_decision_input(item)
        with self.assertRaises(InputValidationError):
            validate_decision_input(accepted_input(source_hash="not-a-hash"))
        with self.assertRaises(InputValidationError):
            validate_decision_input(accepted_input(host_tests_failed=1))

        no_host_evidence = evaluate_fixed_policy(
            accepted_input(
                test_scope="host",
                evidence_scope="host_model",
                host_tests_passed=0,
            ),
            self.policy,
        )
        self.assertEqual("EVIDENCE_REQUIRED", no_host_evidence["verdict"])
        self.assertEqual("COLLECT_MORE_EVIDENCE", no_host_evidence["action_id"])

        host_model_pass = evaluate_fixed_policy(
            accepted_input(test_scope="host", evidence_scope="host_model"),
            self.policy,
        )
        self.assertEqual("PASS_HOST_MODEL", host_model_pass["verdict"])

        with self.assertRaises(InputValidationError):
            validate_decision_input(
                accepted_input(test_scope="host", evidence_scope="hil_physical")
            )
        with self.assertRaises(InputValidationError):
            validate_decision_input(accepted_input(heartbeat_count=0))
        with self.assertRaises(InputValidationError):
            validate_decision_input(accepted_input(heartbeat_max_ms=0))

        mutated_policy = json.loads(json.dumps(self.policy))
        mutated_policy["actions"][0]["description"] = "same version, changed text"
        with self.assertRaises(PolicyValidationError):
            validate_action_policy(mutated_policy)

    def test_source_manifest_is_bound_to_current_file_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "spec.md"
            source.write_bytes(b"version one\n")
            manifest = [
                {"path": "spec.md", "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
            ]
            evidence = accepted_input(
                source_manifest=manifest,
                source_hash=compute_source_hash(manifest),
            )
            self.assertEqual(manifest, verify_source_manifest(root, evidence))
            source.write_bytes(b"tampered\n")
            with self.assertRaises(InputValidationError):
                verify_source_manifest(root, evidence)


class CollectionAndContextTests(unittest.TestCase):
    @staticmethod
    def _real_host_summary() -> dict[str, object]:
        return {
            "total": 4,
            "passed": 2,
            "xfailed": 1,
            "failed": 1,
            "tests": [
                {"test": "UT-PASS-001", "result": "PASS"},
                {"test": "UT-PASS-002", "result": "PASS"},
                {"test": "UT-EXPECTED-RED-001", "result": "XFAIL"},
                {"test": "IT-REAL-FAIL-001", "result": "FAIL"},
            ],
        }

    @staticmethod
    def _real_replay_summary(**changes: object) -> dict[str, object]:
        result: dict[str, object] = {
            "result": "PASS",
            "mode": "OFFLINE_SELF_TEST",
            "test_id": "R19-HS-G2-FULL-PATH-REPLAY-HIL-001",
            "ideal_ground_capture": {
                "expected": 932,
                "parameter_frames": 932,
                "unique": 932,
                "missing": 0,
                "duplicate": 0,
                "out_of_order": 0,
                "parser": {
                    "noise_bytes": 0,
                    "bad_lengths": 0,
                    "bad_crc": 0,
                    "unsupported_flags": 0,
                    "unknown_definition": 0,
                    "partial_bytes": 0,
                },
                "request_to_last_ms": 23575,
                "heartbeat": {
                    "heartbeat_count": 27,
                    "request_to_first_heartbeat_us": 300000,
                    "maximum_gap_us": 1000000,
                    "completion_to_post_heartbeat_us": 725000,
                },
            },
            "firmware_provenance": {"verified": False},
            "e220_profile_provenance": {"verified": False},
            "external_actions": {
                "com_ports_opened": False,
                "serial_bytes_written": False,
                "firmware_write_attempted": False,
                "firmware_changed": False,
            },
        }
        result.update(changes)
        return result

    @staticmethod
    def _sanitizer_contract(summary_sha256: str) -> dict[str, object]:
        return {
            "status": "PASS",
            "verification": {
                "focused_asan_ubsan": {
                    "tests": 1,
                    "passed": 1,
                    "failed": 0,
                    "findings": 0,
                    "summary_sha256": summary_sha256,
                }
            },
        }

    @staticmethod
    def _sanitizer_run() -> dict[str, object]:
        return {
            "test": "IT-BULK-BUDGET-001",
            "result": "PASS",
            "control_bytes_leaked_to_local_uart": 0,
        }

    def test_collects_real_r19_offline_replay_without_upgrading_scope(self) -> None:
        sanitizer_bytes = json.dumps(
            self._sanitizer_run(), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        sanitizer_sha256 = hashlib.sha256(sanitizer_bytes).hexdigest().upper()
        normalized = normalize_r19_offline_replay(
            self._real_host_summary(),
            self._real_replay_summary(),
            self._sanitizer_contract(sanitizer_sha256),
            self._sanitizer_run(),
            sanitizer_run_sha256=sanitizer_sha256,
            run_id="R19-REAL-OFFLINE-001",
            source_manifest=SOURCE_MANIFEST,
            source_hash=compute_source_hash(SOURCE_MANIFEST),
        )
        self.assertEqual("host", normalized["test_scope"])
        self.assertEqual("host_model", normalized["evidence_scope"])
        self.assertEqual(2, normalized["host_tests_passed"])
        self.assertEqual(1, normalized["host_tests_failed"])
        self.assertEqual(["IT-REAL-FAIL-001"], normalized["failed_test_ids"])
        self.assertEqual(932, normalized["received_params"])
        self.assertEqual(23575.0, normalized["completion_ms"])
        self.assertEqual(300.0, normalized["heartbeat_first_ms"])
        self.assertEqual(1000.0, normalized["heartbeat_max_ms"])
        self.assertEqual(725.0, normalized["heartbeat_post_ms"])
        self.assertEqual(0, normalized["sanitizer_errors"])
        self.assertEqual(0, normalized["control_leakage"])
        for field in (
            "retry_identity_status",
            "standard_grant_handoff_status",
            "direction_guard_status",
            "physical_tail_status",
            "vcta_physical_drain_status",
        ):
            self.assertEqual("unknown", normalized[field])
        self.assertFalse(normalized["live_flash_authorized"])

    def test_real_replay_rejects_physical_scope_upgrade_and_partial_unit_guess(self) -> None:
        sanitizer_bytes = json.dumps(
            self._sanitizer_run(), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        sanitizer_sha256 = hashlib.sha256(sanitizer_bytes).hexdigest().upper()
        contract = self._sanitizer_contract(sanitizer_sha256)
        common = {
            "sanitizer_run_sha256": sanitizer_sha256,
            "run_id": "R19-REAL-OFFLINE-002",
            "source_manifest": SOURCE_MANIFEST,
            "source_hash": compute_source_hash(SOURCE_MANIFEST),
        }
        live = self._real_replay_summary(mode="LIVE")
        with self.assertRaises(InputValidationError):
            normalize_r19_offline_replay(
                self._real_host_summary(), live, contract, self._sanitizer_run(), **common
            )

        replay = self._real_replay_summary()
        replay["ideal_ground_capture"]["parser"]["partial_bytes"] = 1  # type: ignore[index]
        with self.assertRaises(InputValidationError):
            normalize_r19_offline_replay(
                self._real_host_summary(), replay, contract, self._sanitizer_run(), **common
            )

    def test_real_replay_rejects_xfail_and_sanitizer_provenance_mismatch(self) -> None:
        sanitizer_bytes = json.dumps(
            self._sanitizer_run(), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        sanitizer_sha256 = hashlib.sha256(sanitizer_bytes).hexdigest().upper()
        common = {
            "sanitizer_run_sha256": sanitizer_sha256,
            "run_id": "R19-REAL-OFFLINE-003",
            "source_manifest": SOURCE_MANIFEST,
            "source_hash": compute_source_hash(SOURCE_MANIFEST),
        }
        host = self._real_host_summary()
        host["xfailed"] = 0
        with self.assertRaises(InputValidationError):
            normalize_r19_offline_replay(
                host,
                self._real_replay_summary(),
                self._sanitizer_contract(sanitizer_sha256),
                self._sanitizer_run(),
                **common,
            )

        with self.assertRaises(InputValidationError):
            normalize_r19_offline_replay(
                self._real_host_summary(),
                self._real_replay_summary(),
                self._sanitizer_contract("0" * 64),
                self._sanitizer_run(),
                **common,
            )

    def test_prepares_real_input_with_a_byte_verified_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence"
            evidence.mkdir()
            host_path = evidence / "host.json"
            replay_path = evidence / "replay.json"
            contract_path = evidence / "sanitizer-contract.json"
            sanitizer_path = evidence / "sanitizer-run.json"
            output_path = root / "prepared" / "input.json"

            sanitizer_bytes = (
                json.dumps(self._sanitizer_run(), indent=2, sort_keys=True) + "\n"
            ).encode("utf-8")
            sanitizer_sha256 = hashlib.sha256(sanitizer_bytes).hexdigest().upper()
            host_path.write_text(
                json.dumps(self._real_host_summary()), encoding="utf-8"
            )
            replay_path.write_text(
                json.dumps(self._real_replay_summary()), encoding="utf-8"
            )
            contract_path.write_text(
                json.dumps(self._sanitizer_contract(sanitizer_sha256)),
                encoding="utf-8",
            )
            sanitizer_path.write_bytes(sanitizer_bytes)

            prepared = prepare_r19_offline_replay_input(
                repo_root=root,
                host_summary_path=host_path,
                replay_summary_path=replay_path,
                sanitizer_contract_path=contract_path,
                sanitizer_run_path=sanitizer_path,
                output_path=output_path,
                run_id="R19-REAL-OFFLINE-004",
            )
            self.assertEqual(prepared, json.loads(output_path.read_text("utf-8")))
            self.assertEqual(
                [
                    "evidence/host.json",
                    "evidence/replay.json",
                    "evidence/sanitizer-contract.json",
                    "evidence/sanitizer-run.json",
                ],
                [entry["path"] for entry in prepared["source_manifest"]],
            )
            verify_source_manifest(root, prepared)
            with self.assertRaises(FileExistsError):
                prepare_r19_offline_replay_input(
                    repo_root=root,
                    host_summary_path=host_path,
                    replay_summary_path=replay_path,
                    sanitizer_contract_path=contract_path,
                    sanitizer_run_path=sanitizer_path,
                    output_path=output_path,
                    run_id="R19-REAL-OFFLINE-004",
                )

    def test_collects_known_summary_shape_with_explicit_measurements(self) -> None:
        normalized = normalize_run(
            {
                "total": 250,
                "passed": 249,
                "failed": 1,
                "failed_test_ids": [
                    "high_speed_tdd_coordinator.grant_handoff"
                ],
            },
            run_id="R19-HOST-002",
            source_manifest=SOURCE_MANIFEST,
            source_hash=compute_source_hash(SOURCE_MANIFEST),
            test_scope="host",
            evidence_scope="host_model",
            measurements={
                key: value
                for key, value in accepted_input().items()
                if key
                not in {
                    "schema_version",
                    "run_id",
                    "source_manifest",
                    "source_hash",
                    "test_scope",
                    "evidence_scope",
                    "host_tests_passed",
                    "host_tests_failed",
                    "failed_test_ids",
                }
            },
        )
        self.assertEqual(249, normalized["host_tests_passed"])
        self.assertEqual(1, normalized["host_tests_failed"])
        self.assertEqual("R19-HOST-002", normalized["run_id"])

    def test_codex_context_requires_action_and_rejects_escape(self) -> None:
        policy = load_action_policy(POLICY)
        code_review_input = accepted_input(crc_errors=1)
        code_review_action = evaluate_run(
            code_review_input,
            policy,
            lambda _: self.fail("fixed failure must not call Jev"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "context"
            with self.assertRaises(ValueError):
                build_context_package(
                    REPO,
                    code_review_input,
                    {"action_id": "RUN_FOCUSED_GRANT_TEST", "confidence": 0.95},
                    policy,
                    output,
                )
            forged_action = dict(code_review_action)
            forged_action["run_id"] = "R19-FORGED-RUN"
            with self.assertRaises(ValueError):
                build_context_package(
                    REPO,
                    code_review_input,
                    forged_action,
                    policy,
                    output,
                )
            bad_policy = json.loads(json.dumps(policy))
            code_review = next(
                action
                for action in bad_policy["actions"]
                if action["action_id"] == "CODE_REVIEW_REQUIRED"
            )
            code_review["context_allowlist"] = ["../outside.txt"]
            with self.assertRaises(ValueError):
                build_context_package(
                    REPO,
                    code_review_input,
                    code_review_action,
                    bad_policy,
                    output,
                )

    def test_codex_context_is_bounded_and_hashed(self) -> None:
        policy = load_action_policy(POLICY)
        code_review_input = accepted_input(crc_errors=1)
        code_review_action = evaluate_run(
            code_review_input,
            policy,
            lambda _: self.fail("fixed failure must not call Jev"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "context"
            manifest = build_context_package(
                REPO,
                code_review_input,
                code_review_action,
                policy,
                output,
            )
            self.assertTrue((output / "context_manifest.json").is_file())
            self.assertLessEqual(
                len(manifest["files"]), policy["context_limits"]["max_optional_files"]
            )
            self.assertFalse(manifest["raw_logs_included"])
            self.assertFalse(manifest["project_wide_bundle"])
            for item in manifest["files"]:
                self.assertEqual(64, len(item["sha256"]))
            manifest_bytes = (output / "context_manifest.json").read_bytes()
            self.assertEqual(
                hashlib.sha256(manifest_bytes).hexdigest(),
                (output / "context_manifest.sha256").read_text("ascii").strip(),
            )
            for item in manifest["generated_artifacts"]:
                self.assertEqual(
                    item["sha256"],
                    hashlib.sha256((output / item["path"]).read_bytes()).hexdigest(),
                )


class ShadowRunnerTests(unittest.TestCase):
    def test_offline_shadow_writes_closed_artifacts_without_api(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path = root / "input.json"
            input_path.write_text(
                json.dumps(
                    accepted_input(
                        host_tests_failed=1,
                        host_tests_passed=249,
                        failed_test_ids=[
                            "high_speed_tdd_coordinator.grant_handoff"
                        ],
                    )
                ),
                encoding="utf-8",
            )
            run_path = run_shadow(
                input_path=input_path,
                output_root=root / "runs",
                policy_path=POLICY,
                enable_network=False,
            )
            final = json.loads((run_path / "final_action.json").read_text("utf-8"))
            summary = json.loads((run_path / "summary.json").read_text("utf-8"))
            self.assertEqual("JEV_DISABLED", final["execution_class"])
            self.assertFalse(final["jev_called"])
            self.assertFalse(summary["hardware_accessed"])
            self.assertFalse(summary["com_opened"])
            self.assertFalse(summary["firmware_flashed"])
            self.assertEqual("hil", summary["test_scope"])
            self.assertEqual("hil_physical", summary["evidence_scope"])
            self.assertTrue(summary["source_manifest_verified"])
            self.assertEqual(4, len(summary["artifact_sha256"]))
            with self.assertRaises(FileExistsError):
                run_shadow(
                    input_path=input_path,
                    output_root=root / "runs",
                    policy_path=POLICY,
                    enable_network=False,
                )

    def test_http_failure_diagnostics_are_sanitized_and_written_to_both_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path = root / "input.json"
            input_path.write_text(
                json.dumps(
                    accepted_input(
                        run_id="R19-HIL-HTTP-FAIL-001",
                        host_tests_failed=1,
                        host_tests_passed=249,
                        failed_test_ids=[
                            "high_speed_tdd_coordinator.grant_handoff"
                        ],
                    )
                ),
                encoding="utf-8",
            )
            calls = 0

            error_body = json.dumps(
                {
                    "error": {
                        "type": "access_denied",
                        "code": "zdr_not_available",
                        "message": "private provider message secret-test-key",
                    }
                }
            ).encode("utf-8")

            def opener(*_args: object, **_kwargs: object) -> object:
                nonlocal calls
                calls += 1
                raise urllib.error.HTTPError(
                    JEV_EVALUATE_ENDPOINT,
                    403,
                    "private HTTP reason secret-test-key",
                    {"Authorization": "Bearer secret-test-key"},
                    io.BytesIO(error_body),
                )

            client = JevGatewayClient("secret-test-key", opener=opener)

            run_path = run_shadow(
                input_path=input_path,
                output_root=root / "runs",
                policy_path=POLICY,
                enable_network=True,
                client=client,
            )
            final_path = run_path / "final_action.json"
            jev_path = run_path / "jev_result.json"
            final = json.loads(final_path.read_text("utf-8"))
            jev = json.loads(jev_path.read_text("utf-8"))

            self.assertEqual(1, calls)
            for artifact in (final, jev):
                self.assertEqual(403, artifact["jev_http_status"])
                self.assertEqual("access_denied", artifact["jev_provider_error_type"])
                self.assertEqual(
                    "zdr_not_available", artifact["jev_provider_error_code"]
                )
                self.assertEqual("JevGatewayError", artifact["jev_error_type"])
            self.assertEqual("ADVISORY_FALLBACK", final["verdict"])
            self.assertEqual("COLLECT_MORE_EVIDENCE", final["action_id"])
            self.assertEqual("API_FALLBACK", final["execution_class"])
            self.assertFalse(final["action_executed"])
            self.assertFalse(final["hardware_accessed"])
            self.assertFalse(final["com_opened"])
            self.assertFalse(final["firmware_flashed"])
            saved = final_path.read_text("utf-8") + jev_path.read_text("utf-8")
            self.assertNotIn("private provider message", saved)
            self.assertNotIn("private HTTP reason", saved)
            self.assertNotIn("Authorization", saved)
            self.assertNotIn("secret-test-key", saved)

    def test_fixed_code_failure_builds_bound_context_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path = root / "input.json"
            input_path.write_text(
                json.dumps(
                    accepted_input(run_id="R19-HIL-FIXED-FAIL-001", crc_errors=1)
                ),
                encoding="utf-8",
            )
            run_path = run_shadow(
                input_path=input_path,
                output_root=root / "runs",
                policy_path=POLICY,
            )
            summary = json.loads((run_path / "summary.json").read_text("utf-8"))
            context = run_path / "codex_context"
            self.assertEqual("FAIL_FIXED", summary["final_verdict"])
            self.assertTrue(summary["codex_context_created"])
            self.assertTrue((context / "context_manifest.json").is_file())
            self.assertTrue((context / "context_manifest.sha256").is_file())

    def test_cli_distinguishes_artifact_success_from_engineering_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            input_path = root / "input.json"
            input_path.write_text(
                json.dumps(
                    accepted_input(run_id="R19-HIL-CLI-FAIL-001", crc_errors=1)
                ),
                encoding="utf-8",
            )
            output = io.StringIO()
            with redirect_stdout(output):
                exit_code = run_shadow_main(
                    [
                        "--input",
                        str(input_path),
                        "--output-root",
                        str(root / "runs"),
                        "--policy",
                        str(POLICY),
                    ]
                )
            self.assertEqual(0, exit_code)
            self.assertIn("ARTIFACTS_WRITTEN verdict=FAIL_FIXED", output.getvalue())
            self.assertNotIn("SHADOW PASS", output.getvalue())


class UsageTests(unittest.TestCase):
    def test_rate_card_is_external_and_total_is_reconciled(self) -> None:
        measurement = calculate_measurement(
            {
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
                "adjudicated_at": "2026-09-23T09:01:00+09:00",
                "retry_count": 0,
                "safety_violation": False,
                "elapsed_seconds": 12.5,
                "jev_cost_usd": 0.0000016,
                "usage_source": "api_exact",
                "jev_generation_id": "gen_test",
                "measured_at": "2026-09-23T09:00:00+09:00",
            },
            {
                "rate_card_version": "test-v1",
                "source_url": "https://example.test/codex-rates",
                "retrieved_at": "2026-09-23T08:00:00+09:00",
                "models": {
                    "test-model": {
                        "input_per_million": 10.0,
                        "cached_input_per_million": 2.0,
                        "output_per_million": 30.0,
                    }
                },
            },
        )
        self.assertEqual("test-v1", measurement["rate_card_version"])
        self.assertAlmostEqual(0.00194, measurement["codex_credits"])

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.jsonl"
            record_measurement(path, measurement)
            saved = json.loads(path.read_text(encoding="utf-8").strip())
            self.assertEqual(measurement, saved)

        broken = dict(measurement)
        broken["total_tokens"] = 151
        with self.assertRaises(MeasurementError):
            calculate_measurement(broken, {"rate_card_version": "x", "models": {}})

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

        fixed_local = {
            key: value
            for key, value in measurement.items()
            if key
            not in {
                "codex_credits",
                "rate_card_version",
                "rate_card_hash",
                "rate_card_source",
                "rate_card_retrieved_at",
            }
        }
        fixed_local.update(
            {
                "codex_called": False,
                "jev_called": False,
                "input_tokens": 0,
                "cached_input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0,
                "jev_input_tokens": 0,
                "jev_output_tokens": 0,
                "action_id": None,
                "confidence": None,
                "route_correct": None,
                "accepted_fix": None,
                "human_adjudication_id": None,
                "adjudicated_at": None,
                "jev_cost_usd": 0.0,
                "jev_generation_id": None,
            }
        )
        fixed_result = calculate_measurement(
            fixed_local,
            {
                "rate_card_version": "test-v1",
                "source_url": "https://example.test/codex-rates",
                "retrieved_at": "2026-09-23T08:00:00+09:00",
                "models": {
                    "test-model": {
                        "input_per_million": 10.0,
                        "cached_input_per_million": 2.0,
                        "output_per_million": 30.0,
                    }
                },
            },
        )
        self.assertEqual(0.0, fixed_result["codex_credits"])


if __name__ == "__main__":
    unittest.main()
