"""Explicit adapters from known saved summaries to the closed R19 input."""

from __future__ import annotations

import math
import hashlib
import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .policy_gate import (
    InputValidationError,
    compute_source_hash,
    validate_decision_input,
)


_RESERVED = frozenset(
    {
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
)

_MAX_SAVED_SUMMARY_BYTES = 64 * 1024 * 1024


def _count(summary: Mapping[str, Any], name: str) -> int:
    value = summary.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InputValidationError(f"summary.{name} must be a non-negative integer")
    return value


def _object(parent: Mapping[str, Any], name: str, *, prefix: str) -> Mapping[str, Any]:
    value = parent.get(name)
    if not isinstance(value, Mapping):
        raise InputValidationError(f"{prefix}.{name} must be an object")
    return value


def _integer(
    parent: Mapping[str, Any], name: str, *, prefix: str, minimum: int = 0
) -> int:
    value = parent.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise InputValidationError(
            f"{prefix}.{name} must be an integer >= {minimum}"
        )
    return value


def _number(
    parent: Mapping[str, Any], name: str, *, prefix: str, exclusive_minimum: float = 0
) -> float:
    value = parent.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputValidationError(f"{prefix}.{name} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result <= exclusive_minimum:
        raise InputValidationError(
            f"{prefix}.{name} must be finite and > {exclusive_minimum}"
        )
    return result


def _real_host_counts(summary: Mapping[str, Any]) -> tuple[int, int, list[str]]:
    """Read the sealed host-runner aggregate without counting expected REDs.

    The repository runner records expected failures as ``XFAIL``.  They remain
    part of ``total`` but are neither passing evidence nor an unexplained
    failure routed to Jev.
    """

    passed = _integer(summary, "passed", prefix="host_summary")
    failed = _integer(summary, "failed", prefix="host_summary")
    xfailed = _integer(summary, "xfailed", prefix="host_summary")
    total = _integer(summary, "total", prefix="host_summary")
    tests = summary.get("tests")
    if not isinstance(tests, list):
        raise InputValidationError("host_summary.tests must be an array")
    if total != passed + failed + xfailed or total != len(tests):
        raise InputValidationError(
            "host_summary total must equal passed + failed + xfailed and tests length"
        )

    observed = {"PASS": 0, "FAIL": 0, "XFAIL": 0}
    failed_test_ids: list[str] = []
    seen: set[str] = set()
    for index, row in enumerate(tests):
        if not isinstance(row, Mapping):
            raise InputValidationError(f"host_summary.tests[{index}] must be an object")
        test_id = row.get("test")
        result = row.get("result")
        if not isinstance(test_id, str) or not test_id:
            raise InputValidationError(
                f"host_summary.tests[{index}].test must be a non-empty string"
            )
        if test_id in seen:
            raise InputValidationError(f"duplicate host test id: {test_id}")
        seen.add(test_id)
        if result not in observed:
            raise InputValidationError(
                f"host_summary.tests[{index}].result is unsupported"
            )
        observed[str(result)] += 1
        if result == "FAIL":
            failed_test_ids.append(test_id)

    if observed != {"PASS": passed, "FAIL": failed, "XFAIL": xfailed}:
        raise InputValidationError("host_summary counters do not match tests array")
    return passed, failed, failed_test_ids


def normalize_r19_offline_replay(
    host_summary: Mapping[str, Any],
    replay_summary: Mapping[str, Any],
    sanitizer_contract: Mapping[str, Any],
    sanitizer_run: Mapping[str, Any],
    *,
    sanitizer_run_sha256: str,
    run_id: str,
    source_manifest: list[dict[str, str]],
    source_hash: str,
) -> dict[str, Any]:
    """Normalize the known R19 full-path offline replay, never as physical HIL.

    Only values present in the saved summaries are mapped.  The five physical
    handoff/tail claims are absent from this replay and therefore remain
    ``unknown``.  Fixed policy will request evidence before Jev is considered.
    """

    if not isinstance(host_summary, Mapping):
        raise InputValidationError("host_summary must be an object")
    if not isinstance(replay_summary, Mapping):
        raise InputValidationError("replay_summary must be an object")
    if not isinstance(sanitizer_contract, Mapping):
        raise InputValidationError("sanitizer_contract must be an object")
    if not isinstance(sanitizer_run, Mapping):
        raise InputValidationError("sanitizer_run must be an object")

    passed, failed, failed_test_ids = _real_host_counts(host_summary)
    if replay_summary.get("test_id") != "R19-HS-G2-FULL-PATH-REPLAY-HIL-001":
        raise InputValidationError("unsupported replay_summary.test_id")
    if replay_summary.get("mode") != "OFFLINE_SELF_TEST":
        raise InputValidationError("R19 full-path replay must remain host_model")
    if replay_summary.get("result") != "PASS":
        raise InputValidationError("replay_summary.result must be PASS")

    capture = _object(
        replay_summary, "ideal_ground_capture", prefix="replay_summary"
    )
    expected = _integer(capture, "expected", prefix="replay_summary.ideal_ground_capture")
    if expected != 932:
        raise InputValidationError("replay expected parameter count must be 932")
    parameter_frames = _integer(
        capture, "parameter_frames", prefix="replay_summary.ideal_ground_capture"
    )
    unique = _integer(capture, "unique", prefix="replay_summary.ideal_ground_capture")
    missing = _integer(capture, "missing", prefix="replay_summary.ideal_ground_capture")
    duplicate = _integer(
        capture, "duplicate", prefix="replay_summary.ideal_ground_capture"
    )
    out_of_order = _integer(
        capture, "out_of_order", prefix="replay_summary.ideal_ground_capture"
    )
    if parameter_frames < unique or unique + missing != expected:
        raise InputValidationError("replay parameter accounting is inconsistent")
    if missing != 0:
        raise InputValidationError(
            "replay does not expose first_missing_index for incomplete captures"
        )

    parser = _object(capture, "parser", prefix="replay_summary.ideal_ground_capture")
    crc_errors = _integer(
        parser, "bad_crc", prefix="replay_summary.ideal_ground_capture.parser"
    )
    partial_bytes = _integer(
        parser, "partial_bytes", prefix="replay_summary.ideal_ground_capture.parser"
    )
    if partial_bytes != 0:
        raise InputValidationError(
            "partial_bytes cannot be guessed as a partial frame count"
        )
    parser_errors = sum(
        _integer(parser, name, prefix="replay_summary.ideal_ground_capture.parser")
        for name in (
            "noise_bytes",
            "bad_lengths",
            "unsupported_flags",
            "unknown_definition",
        )
    )

    heartbeat = _object(
        capture, "heartbeat", prefix="replay_summary.ideal_ground_capture"
    )
    heartbeat_count = _integer(
        heartbeat,
        "heartbeat_count",
        prefix="replay_summary.ideal_ground_capture.heartbeat",
        minimum=1,
    )
    heartbeat_first_ms = _number(
        heartbeat,
        "request_to_first_heartbeat_us",
        prefix="replay_summary.ideal_ground_capture.heartbeat",
    ) / 1000.0
    heartbeat_max_ms = _number(
        heartbeat,
        "maximum_gap_us",
        prefix="replay_summary.ideal_ground_capture.heartbeat",
    ) / 1000.0
    heartbeat_post_ms = _number(
        heartbeat,
        "completion_to_post_heartbeat_us",
        prefix="replay_summary.ideal_ground_capture.heartbeat",
    ) / 1000.0

    verification = _object(
        sanitizer_contract, "verification", prefix="sanitizer_contract"
    )
    asan = _object(
        verification, "focused_asan_ubsan", prefix="sanitizer_contract.verification"
    )
    if sanitizer_contract.get("status") != "PASS":
        raise InputValidationError("sanitizer_contract.status must be PASS")
    sanitizer_tests = _integer(
        asan, "tests", prefix="sanitizer_contract.verification.focused_asan_ubsan"
    )
    sanitizer_passed = _integer(
        asan, "passed", prefix="sanitizer_contract.verification.focused_asan_ubsan"
    )
    sanitizer_failed = _integer(
        asan, "failed", prefix="sanitizer_contract.verification.focused_asan_ubsan"
    )
    sanitizer_errors = _integer(
        asan, "findings", prefix="sanitizer_contract.verification.focused_asan_ubsan"
    )
    if sanitizer_tests != sanitizer_passed + sanitizer_failed or sanitizer_failed != 0:
        raise InputValidationError("sanitizer contract did not complete cleanly")
    recorded_digest = asan.get("summary_sha256")
    if (
        not isinstance(recorded_digest, str)
        or not isinstance(sanitizer_run_sha256, str)
        or recorded_digest.upper() != sanitizer_run_sha256.upper()
    ):
        raise InputValidationError("sanitizer summary digest mismatch")
    if sanitizer_run.get("result") != "PASS":
        raise InputValidationError("sanitizer_run.result must be PASS")
    if sanitizer_run.get("test") != "IT-BULK-BUDGET-001":
        raise InputValidationError("unsupported sanitizer_run.test")
    control_leakage = _integer(
        sanitizer_run, "control_bytes_leaked_to_local_uart", prefix="sanitizer_run"
    )

    firmware = _object(replay_summary, "firmware_provenance", prefix="replay_summary")
    profile = _object(
        replay_summary, "e220_profile_provenance", prefix="replay_summary"
    )
    if firmware.get("verified") is not False or profile.get("verified") is not False:
        raise InputValidationError("offline replay provenance must remain unverified")
    external_actions = _object(
        replay_summary, "external_actions", prefix="replay_summary"
    )
    for field in (
        "com_ports_opened",
        "serial_bytes_written",
        "firmware_write_attempted",
        "firmware_changed",
    ):
        if external_actions.get(field) is not False:
            raise InputValidationError(f"offline replay unexpectedly set {field}")

    normalized = {
        "schema_version": "r19-jev-input-2",
        "run_id": run_id,
        "source_manifest": source_manifest,
        "source_hash": source_hash,
        "test_scope": "host",
        "evidence_scope": "host_model",
        "host_tests_passed": passed,
        "host_tests_failed": failed,
        "failed_test_ids": failed_test_ids,
        "sanitizer_errors": sanitizer_errors,
        "expected_params": expected,
        "received_params": unique,
        "first_missing_index": None,
        "completion_ms": _number(
            capture,
            "request_to_last_ms",
            prefix="replay_summary.ideal_ground_capture",
        ),
        "heartbeat_count": heartbeat_count,
        "heartbeat_first_ms": heartbeat_first_ms,
        "heartbeat_max_ms": heartbeat_max_ms,
        "heartbeat_post_ms": heartbeat_post_ms,
        "missing_params": missing,
        "duplicate_params": duplicate,
        "out_of_order_params": out_of_order,
        "crc_errors": crc_errors,
        "parser_errors": parser_errors,
        "partial_frames": 0,
        "control_leakage": control_leakage,
        "retry_identity_status": "unknown",
        "standard_grant_handoff_status": "unknown",
        "direction_guard_status": "unknown",
        "physical_tail_status": "unknown",
        "vcta_physical_drain_status": "unknown",
        "live_flash_authorized": False,
        "hardware_operation_requested": False,
        "communication_parameter_change_requested": False,
        "acceptance_relaxation_requested": False,
    }
    return validate_decision_input(normalized)


def _read_saved_summary(path: Path, *, label: str) -> tuple[dict[str, Any], bytes]:
    resolved = path.resolve(strict=True)
    if resolved.stat().st_size > _MAX_SAVED_SUMMARY_BYTES:
        raise InputValidationError(f"{label} exceeds the saved-summary size limit")
    try:
        encoded = resolved.read_bytes()
        value = json.loads(encoded.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InputValidationError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise InputValidationError(f"{label} must be a JSON object")
    return value, encoded


def _source_entry(repo_root: Path, path: Path, encoded: bytes) -> dict[str, str]:
    resolved = path.resolve(strict=True)
    try:
        relative = resolved.relative_to(repo_root)
    except ValueError as error:
        raise InputValidationError("source summary escapes repo_root") from error
    relative_text = relative.as_posix()
    if not relative_text or relative_text.startswith("../"):
        raise InputValidationError("source summary path is invalid")
    return {
        "path": relative_text,
        "sha256": hashlib.sha256(encoded).hexdigest().upper(),
    }


def prepare_r19_offline_replay_input(
    *,
    repo_root: Path | str,
    host_summary_path: Path | str,
    replay_summary_path: Path | str,
    sanitizer_contract_path: Path | str,
    sanitizer_run_path: Path | str,
    output_path: Path | str,
    run_id: str,
) -> dict[str, Any]:
    """Create one closed input from byte-bound, saved R19 host evidence."""

    root = Path(repo_root).resolve(strict=True)
    sources = [
        ("host_summary", Path(host_summary_path)),
        ("replay_summary", Path(replay_summary_path)),
        ("sanitizer_contract", Path(sanitizer_contract_path)),
        ("sanitizer_run", Path(sanitizer_run_path)),
    ]
    decoded: dict[str, dict[str, Any]] = {}
    encoded_by_label: dict[str, bytes] = {}
    manifest: list[dict[str, str]] = []
    for label, path in sources:
        value, encoded = _read_saved_summary(path, label=label)
        decoded[label] = value
        encoded_by_label[label] = encoded
        manifest.append(_source_entry(root, path, encoded))
    if len({entry["path"] for entry in manifest}) != len(manifest):
        raise InputValidationError("source summaries must be distinct files")

    sanitizer_digest = hashlib.sha256(encoded_by_label["sanitizer_run"]).hexdigest()
    prepared = normalize_r19_offline_replay(
        decoded["host_summary"],
        decoded["replay_summary"],
        decoded["sanitizer_contract"],
        decoded["sanitizer_run"],
        sanitizer_run_sha256=sanitizer_digest,
        run_id=run_id,
        source_manifest=manifest,
        source_hash=compute_source_hash(manifest),
    )

    destination = Path(output_path).resolve(strict=False)
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(prepared, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    with destination.open("xb") as stream:
        stream.write(payload)
        stream.flush()
    return prepared


def normalize_run(
    summary: Mapping[str, Any],
    *,
    run_id: str,
    source_manifest: list[dict[str, str]],
    source_hash: str,
    test_scope: str,
    evidence_scope: str,
    measurements: Mapping[str, Any],
) -> dict[str, Any]:
    """Normalize only the documented aggregate host-summary shape.

    Measurement extraction remains explicit; unknown summary formats are not
    guessed because a guessed zero could incorrectly turn a fixed failure into
    a pass.
    """

    if not isinstance(summary, Mapping):
        raise InputValidationError("summary must be an object")
    passed = _count(summary, "passed")
    failed = _count(summary, "failed")
    if "total" in summary and _count(summary, "total") != passed + failed:
        raise InputValidationError("summary total does not equal passed + failed")
    if not isinstance(measurements, Mapping):
        raise InputValidationError("measurements must be an object")
    failed_test_ids = summary.get("failed_test_ids")
    if not isinstance(failed_test_ids, list):
        raise InputValidationError("summary.failed_test_ids must be an array")
    collisions = sorted(_RESERVED.intersection(measurements))
    if collisions:
        raise InputValidationError(
            f"measurements cannot override reserved fields: {', '.join(collisions)}"
        )

    normalized: dict[str, Any] = {
        "schema_version": "r19-jev-input-2",
        "run_id": run_id,
        "source_manifest": source_manifest,
        "source_hash": source_hash,
        "test_scope": test_scope,
        "evidence_scope": evidence_scope,
        "host_tests_passed": passed,
        "host_tests_failed": failed,
        "failed_test_ids": list(failed_test_ids),
    }
    normalized.update(measurements)
    return validate_decision_input(normalized)
