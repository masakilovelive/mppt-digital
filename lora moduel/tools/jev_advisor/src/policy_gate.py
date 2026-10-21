"""Fail-closed validation and deterministic R19 acceptance routing."""

from __future__ import annotations

import json
import hashlib
import math
import re
from collections.abc import Mapping
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA_VERSION = "r19-jev-input-2"
ACTION_IDS = frozenset(
    {
        "RUN_FOCUSED_GRANT_TEST",
        "RUN_DIRECTION_GUARD_TEST",
        "INSPECT_FINAL_VCB1_TAIL",
        "INSPECT_VCTA_PHYSICAL_DRAIN",
        "COLLECT_MORE_EVIDENCE",
        "CODE_REVIEW_REQUIRED",
        "HUMAN_REVIEW_REQUIRED",
        "STOP_SAFETY_CONDITION",
    }
)

DECISION_FIELDS = frozenset(
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
        "sanitizer_errors",
        "expected_params",
        "received_params",
        "first_missing_index",
        "completion_ms",
        "heartbeat_first_ms",
        "heartbeat_max_ms",
        "heartbeat_post_ms",
        "heartbeat_count",
        "missing_params",
        "duplicate_params",
        "out_of_order_params",
        "crc_errors",
        "parser_errors",
        "partial_frames",
        "control_leakage",
        "retry_identity_status",
        "standard_grant_handoff_status",
        "direction_guard_status",
        "physical_tail_status",
        "vcta_physical_drain_status",
        "live_flash_authorized",
        "hardware_operation_requested",
        "communication_parameter_change_requested",
        "acceptance_relaxation_requested",
    }
)

_INTEGER_FIELDS = frozenset(
    {
        "host_tests_passed",
        "host_tests_failed",
        "sanitizer_errors",
        "expected_params",
        "received_params",
        "missing_params",
        "duplicate_params",
        "out_of_order_params",
        "crc_errors",
        "parser_errors",
        "partial_frames",
        "control_leakage",
        "heartbeat_count",
    }
)
_NUMBER_FIELDS = frozenset(
    {
        "completion_ms",
        "heartbeat_first_ms",
        "heartbeat_max_ms",
        "heartbeat_post_ms",
    }
)
_BOOLEAN_FIELDS = frozenset(
    {
        "live_flash_authorized",
        "hardware_operation_requested",
        "communication_parameter_change_requested",
        "acceptance_relaxation_requested",
    }
)
_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SHA256 = re.compile(r"^[A-Fa-f0-9]{64}$")
_TEST_ID = re.compile(r"^[A-Za-z0-9_./:+-]{1,160}$")
_EVIDENCE_STATUSES = frozenset({"proven", "disproven", "unknown"})
_STATUS_FIELDS = frozenset(
    {
        "retry_identity_status",
        "standard_grant_handoff_status",
        "direction_guard_status",
        "physical_tail_status",
        "vcta_physical_drain_status",
    }
)
_FORBIDDEN_OPERATIONS = frozenset(
    {
        "vehicle_ground_auto_flash",
        "automatic_com_operation",
        "e220_persistent_setting_change",
        "uart_air_rate_sub_packet_tdd_change",
        "live_flash_authorized_mutation",
        "acceptance_threshold_relaxation",
        "fixed_fail_override",
    }
)
_ACTION_CONTRACT = {
    "RUN_FOCUSED_GRANT_TEST": (
        "GRANT_HANDOFF_SUSPECTED",
        "focused_host_test",
        True,
        False,
        False,
    ),
    "RUN_DIRECTION_GUARD_TEST": (
        "DIRECTION_GUARD_BOUNDARY_SUSPECTED",
        "focused_host_test",
        True,
        False,
        False,
    ),
    "INSPECT_FINAL_VCB1_TAIL": (
        "FINAL_VCB1_TAIL_UNPROVEN",
        "read_only_inspection",
        True,
        False,
        False,
    ),
    "INSPECT_VCTA_PHYSICAL_DRAIN": (
        "VCTA_PHYSICAL_DRAIN_UNPROVEN",
        "read_only_inspection",
        True,
        False,
        False,
    ),
    "COLLECT_MORE_EVIDENCE": (
        "EVIDENCE_INSUFFICIENT_OR_LOW_CONFIDENCE",
        "evidence_request",
        False,
        False,
        True,
    ),
    "CODE_REVIEW_REQUIRED": (
        "UNKNOWN_OR_SOURCE_LEVEL_DEFECT",
        "codex_escalation",
        False,
        True,
        True,
    ),
    "HUMAN_REVIEW_REQUIRED": (
        "AUTHORIZATION_OR_AMBIGUOUS_OPERATION_REQUIRED",
        "human_escalation",
        False,
        False,
        True,
    ),
    "STOP_SAFETY_CONDITION": (
        "SAFETY_RULE_OR_FIXED_ACCEPTANCE_VIOLATION",
        "safety_stop",
        False,
        False,
        True,
    ),
}
_RAW_LOG_SUFFIXES = frozenset({".log", ".tlog", ".trace", ".raw", ".bin", ".csv"})
_POLICY_SEMANTIC_SHA256 = (
    "51360429b729a492b2c348921870ed9ed69a461a76c6d57be19c5bf94fafb26d"
)


class InputValidationError(ValueError):
    """Raised when bounded decision evidence is missing or inconsistent."""


class PolicyValidationError(ValueError):
    """Raised when the action policy would weaken the Phase-A contract."""


def _canonical_manifest(source_manifest: Any) -> list[dict[str, str]]:
    if not isinstance(source_manifest, list) or not 1 <= len(source_manifest) <= 64:
        raise InputValidationError("source_manifest must contain 1..64 file records")
    canonical: list[dict[str, str]] = []
    seen: set[str] = set()
    for entry in source_manifest:
        if not isinstance(entry, Mapping):
            raise InputValidationError("source_manifest entries must be objects")
        if frozenset(entry.keys()) != {"path", "sha256"}:
            raise InputValidationError("source_manifest entries have unexpected fields")
        path = entry["path"]
        digest = entry["sha256"]
        if (
            not isinstance(path, str)
            or not 1 <= len(path) <= 512
            or "\\" in path
            or any(c in path for c in "*?[]")
        ):
            raise InputValidationError("source_manifest path must be explicit POSIX-relative")
        parsed = PurePosixPath(path)
        if parsed.is_absolute() or not parsed.parts or any(part in {"", ".", ".."} for part in parsed.parts):
            raise InputValidationError("source_manifest path escapes its source root")
        normalized = parsed.as_posix()
        if normalized in seen:
            raise InputValidationError("source_manifest paths must be unique")
        if not isinstance(digest, str) or not _SHA256.fullmatch(digest):
            raise InputValidationError("source_manifest sha256 is invalid")
        seen.add(normalized)
        canonical.append({"path": normalized, "sha256": digest.lower()})
    return sorted(canonical, key=lambda value: value["path"])


def compute_source_hash(source_manifest: Any) -> str:
    """Hash a normalized path+file-hash manifest for a Git-independent snapshot."""

    canonical = _canonical_manifest(source_manifest)
    encoded = json.dumps(
        canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def verify_source_manifest(
    source_root: Path | str, item: Mapping[str, Any]
) -> list[dict[str, str]]:
    """Bind a decision input to the current bytes of its explicit source files."""

    evidence = validate_decision_input(item)
    root = Path(source_root).resolve(strict=True)
    verified: list[dict[str, str]] = []
    for entry in _canonical_manifest(evidence["source_manifest"]):
        candidate = (root / Path(entry["path"])).resolve(strict=True)
        try:
            candidate.relative_to(root)
        except ValueError as error:
            raise InputValidationError("source_manifest file escapes source root") from error
        if not candidate.is_file():
            raise InputValidationError("source_manifest entry is not a file")
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if digest != entry["sha256"]:
            raise InputValidationError(
                f"source_manifest hash mismatch: {entry['path']}"
            )
        verified.append(entry)
    return verified


def _require_nonnegative_integer(item: Mapping[str, Any], name: str) -> int:
    value = item[name]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise InputValidationError(f"{name} must be a non-negative integer")
    return value


def _require_nonnegative_number(item: Mapping[str, Any], name: str) -> float:
    value = item[name]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputValidationError(f"{name} must be a finite non-negative number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise InputValidationError(f"{name} must be a finite non-negative number")
    return number


def validate_decision_input(item: Mapping[str, Any]) -> dict[str, Any]:
    """Validate the closed R19 input and its cross-field accounting."""

    if not isinstance(item, Mapping):
        raise InputValidationError("decision input must be an object")
    actual = frozenset(item.keys())
    missing = sorted(DECISION_FIELDS - actual)
    extra = sorted(actual - DECISION_FIELDS)
    if missing:
        raise InputValidationError(f"missing required fields: {', '.join(missing)}")
    if extra:
        raise InputValidationError(f"unexpected fields: {', '.join(extra)}")

    if item["schema_version"] != SCHEMA_VERSION:
        raise InputValidationError("unsupported schema_version")
    if not isinstance(item["run_id"], str) or not _RUN_ID.fullmatch(item["run_id"]):
        raise InputValidationError("run_id has an invalid format")
    if not isinstance(item["source_hash"], str) or not _SHA256.fullmatch(
        item["source_hash"]
    ):
        raise InputValidationError("source_hash must be a SHA-256 hex digest")
    computed_source_hash = compute_source_hash(item["source_manifest"])
    if item["source_hash"].lower() != computed_source_hash:
        raise InputValidationError("source_hash does not match source_manifest")
    if item["test_scope"] not in {"host", "hil"}:
        raise InputValidationError("test_scope must be host or hil")
    if item["evidence_scope"] not in {"host_model", "hil_physical"}:
        raise InputValidationError(
            "evidence_scope must be host_model or hil_physical"
        )
    expected_evidence_scope = (
        "host_model" if item["test_scope"] == "host" else "hil_physical"
    )
    if item["evidence_scope"] != expected_evidence_scope:
        raise InputValidationError("test_scope and evidence_scope are inconsistent")

    integers = {name: _require_nonnegative_integer(item, name) for name in _INTEGER_FIELDS}
    for name in _NUMBER_FIELDS:
        if _require_nonnegative_number(item, name) <= 0:
            raise InputValidationError(f"{name} must be greater than zero")
    if integers["heartbeat_count"] <= 0:
        raise InputValidationError("heartbeat_count must be greater than zero")
    for name in _BOOLEAN_FIELDS:
        if not isinstance(item[name], bool):
            raise InputValidationError(f"{name} must be boolean")
    for name in _STATUS_FIELDS:
        if item[name] not in _EVIDENCE_STATUSES:
            raise InputValidationError(
                f"{name} must be proven, disproven, or unknown"
            )

    failed_test_ids = item["failed_test_ids"]
    if not isinstance(failed_test_ids, list) or len(failed_test_ids) > 64:
        raise InputValidationError("failed_test_ids must be an array of at most 64 IDs")
    if any(
        not isinstance(test_id, str) or not _TEST_ID.fullmatch(test_id)
        for test_id in failed_test_ids
    ):
        raise InputValidationError("failed_test_ids contains an invalid test ID")
    if len(set(failed_test_ids)) != len(failed_test_ids):
        raise InputValidationError("failed_test_ids must not contain duplicates")
    if len(failed_test_ids) != integers["host_tests_failed"]:
        raise InputValidationError(
            "failed_test_ids count must equal host_tests_failed"
        )

    if integers["expected_params"] != 932:
        raise InputValidationError("expected_params must remain exactly 932")
    if integers["received_params"] > integers["expected_params"]:
        raise InputValidationError("received_params cannot exceed expected_params")
    if integers["missing_params"] != (
        integers["expected_params"] - integers["received_params"]
    ):
        raise InputValidationError(
            "missing_params must equal expected_params - received_params"
        )

    first_missing = item["first_missing_index"]
    if integers["missing_params"] == 0:
        if first_missing is not None:
            raise InputValidationError(
                "first_missing_index must be null when no parameters are missing"
            )
    else:
        if (
            isinstance(first_missing, bool)
            or not isinstance(first_missing, int)
            or not 0 <= first_missing < integers["expected_params"]
        ):
            raise InputValidationError(
                "first_missing_index must identify a missing parameter"
            )

    return dict(item)


def _action_map(policy: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    actions = policy.get("actions")
    if not isinstance(actions, list):
        raise PolicyValidationError("policy actions must be an array")
    result: dict[str, Mapping[str, Any]] = {}
    for action in actions:
        if not isinstance(action, Mapping):
            raise PolicyValidationError("each policy action must be an object")
        action_id = action.get("action_id")
        if not isinstance(action_id, str) or action_id in result:
            raise PolicyValidationError("policy action IDs must be unique strings")
        result[action_id] = action
    if frozenset(result) != ACTION_IDS:
        raise PolicyValidationError("policy action catalog is not the closed R19 set")
    return result


def get_action(policy: Mapping[str, Any], action_id: str) -> Mapping[str, Any]:
    """Return one validated action record by its closed identifier."""

    return _action_map(policy)[action_id]


def validate_action_policy(policy: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(policy, Mapping):
        raise PolicyValidationError("action policy must be an object")
    try:
        semantic_bytes = json.dumps(
            dict(policy),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise PolicyValidationError("action policy is not canonical JSON") from error
    if hashlib.sha256(semantic_bytes).hexdigest() != _POLICY_SEMANTIC_SHA256:
        raise PolicyValidationError("policy content does not match its pinned version")
    if policy.get("policy_version") != "r19-actions-2":
        raise PolicyValidationError("unsupported policy version")
    if policy.get("input_schema_version") != SCHEMA_VERSION:
        raise PolicyValidationError("policy/input schema version mismatch")

    phase_a = policy.get("phase_a")
    if not isinstance(phase_a, Mapping):
        raise PolicyValidationError("missing Phase-A policy")
    required_phase = {
        "mode": "shadow_evaluation",
        "execute_actions": False,
        "hardware_access_allowed": False,
        "com_access_allowed": False,
        "firmware_write_allowed": False,
        "human_decision_comparison_required": True,
        "token_savings_are_simulated": True,
    }
    for name, expected in required_phase.items():
        if phase_a.get(name) != expected:
            raise PolicyValidationError(f"unsafe Phase-A setting: {name}")

    fixed = policy.get("fixed_acceptance")
    if not isinstance(fixed, Mapping):
        raise PolicyValidationError("missing fixed acceptance policy")
    if (
        fixed.get("expected_params") != 932
        or fixed.get("max_elapsed_ms") != 30000
        or fixed.get("max_heartbeat_gap_ms") != 2500
        or fixed.get("max_error_count") != 0
    ):
        raise PolicyValidationError("fixed R19 acceptance criteria were changed")

    confidence = policy.get("confidence_routing")
    if not isinstance(confidence, Mapping):
        raise PolicyValidationError("missing confidence routing policy")
    try:
        valid_thresholds = (
            confidence["high"]["minimum"] == 0.9
            and confidence["review"]["minimum"] == 0.7
            and confidence["review"]["maximum_exclusive"] == 0.9
            and confidence["low"]["maximum_exclusive"] == 0.7
            and confidence["low"]["forced_action_id"]
            == "COLLECT_MORE_EVIDENCE"
            and confidence["safety_condition"]["forced_action_id"]
            == "STOP_SAFETY_CONDITION"
        )
    except (KeyError, TypeError):
        valid_thresholds = False
    if not valid_thresholds:
        raise PolicyValidationError("confidence thresholds are not the R19 values")

    if frozenset(policy.get("forbidden_operations", [])) != _FORBIDDEN_OPERATIONS:
        raise PolicyValidationError("forbidden operation catalog was changed")
    context_limits = policy.get("context_limits")
    if not isinstance(context_limits, Mapping) or (
        context_limits.get("max_optional_files") != 12
        or context_limits.get("project_wide_source_upload_allowed") is not False
        or context_limits.get("raw_log_upload_allowed") is not False
        or context_limits.get("source_manifest_required") is not True
    ):
        raise PolicyValidationError("context limits are not the closed Phase-A values")

    actions = _action_map(policy)
    for action_id, action in actions.items():
        if action.get("phase_a_effect") != "record_only":
            raise PolicyValidationError(f"{action_id} is not shadow-only")
        if not isinstance(action.get("context_allowlist"), list):
            raise PolicyValidationError(f"{action_id} lacks a context allowlist")
        expected = _ACTION_CONTRACT[action_id]
        actual = (
            action.get("cause_id"),
            action.get("category"),
            action.get("future_high_confidence_candidate"),
            action.get("requires_codex"),
            action.get("requires_human"),
        )
        if actual != expected:
            raise PolicyValidationError(f"{action_id} semantics were changed")
        allowlist = action["context_allowlist"]
        if len(allowlist) > context_limits["max_optional_files"]:
            raise PolicyValidationError(f"{action_id} allowlist exceeds its limit")
        for template in allowlist:
            if not isinstance(template, str):
                raise PolicyValidationError(f"{action_id} has a non-string path")
            replaced = template.replace("<run_id>", "RUN_ID")
            if "\\" in replaced or any(c in replaced for c in "*?[]"):
                raise PolicyValidationError(f"{action_id} has an unbounded path")
            parsed = PurePosixPath(replaced)
            if parsed.is_absolute() or any(part in {"", ".", ".."} for part in parsed.parts):
                raise PolicyValidationError(f"{action_id} has an escaping path")
            if parsed.suffix.lower() in _RAW_LOG_SUFFIXES:
                raise PolicyValidationError(f"{action_id} allowlists a raw log")

    return dict(policy)


def load_action_policy(path: Path | str) -> dict[str, Any]:
    """Load and validate the version-pinned local policy."""

    policy_path = Path(path)
    try:
        raw = policy_path.read_text(encoding="utf-8")
        parsed = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PolicyValidationError(f"cannot load action policy: {error}") from error
    return validate_action_policy(parsed)


def _result(
    verdict: str,
    action_id: str | None,
    reasons: list[str],
    policy: Mapping[str, Any],
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "verdict": verdict,
        "action_id": action_id,
        "reasons": reasons,
        "policy_version": policy["policy_version"],
    }
    if action_id is not None:
        action = get_action(policy, action_id)
        result["cause_id"] = action["cause_id"]
    return result


def evaluate_fixed_policy(
    item: Mapping[str, Any], policy: Mapping[str, Any]
) -> dict[str, Any]:
    """Apply rules that neither Jev nor Codex is allowed to override."""

    evidence = validate_decision_input(item)
    validate_action_policy(policy)

    safety_fields = [
        "hardware_operation_requested",
        "communication_parameter_change_requested",
        "acceptance_relaxation_requested",
    ]
    safety_hits = [name for name in safety_fields if evidence[name]]
    if safety_hits:
        return _result("STOP", "STOP_SAFETY_CONDITION", safety_hits, policy)

    zero_fields = [
        "sanitizer_errors",
        "missing_params",
        "duplicate_params",
        "out_of_order_params",
        "crc_errors",
        "parser_errors",
        "partial_frames",
        "control_leakage",
    ]
    failures = [name for name in zero_fields if evidence[name] != 0]
    if evidence["received_params"] != evidence["expected_params"]:
        failures.append("received_params")
    if evidence["completion_ms"] > policy["fixed_acceptance"]["max_elapsed_ms"]:
        failures.append("completion_ms")
    for name in ("heartbeat_first_ms", "heartbeat_max_ms", "heartbeat_post_ms"):
        if evidence[name] > policy["fixed_acceptance"]["max_heartbeat_gap_ms"]:
            failures.append(name)
    if failures:
        return _result("FAIL_FIXED", "CODE_REVIEW_REQUIRED", failures, policy)

    evidence_routes = [
        (
            "retry_identity_status",
            "RUN_FOCUSED_GRANT_TEST",
        ),
        (
            "standard_grant_handoff_status",
            "RUN_FOCUSED_GRANT_TEST",
        ),
        ("direction_guard_status", "RUN_DIRECTION_GUARD_TEST"),
        ("physical_tail_status", "INSPECT_FINAL_VCB1_TAIL"),
        ("vcta_physical_drain_status", "INSPECT_VCTA_PHYSICAL_DRAIN"),
    ]
    for field, action_id in evidence_routes:
        if evidence[field] == "disproven":
            return _result("FAIL_FIXED", action_id, [field], policy)
        if evidence[field] == "unknown":
            return _result("EVIDENCE_REQUIRED", action_id, [field], policy)

    if (
        evidence["test_scope"] == "host"
        and evidence["host_tests_passed"] + evidence["host_tests_failed"] == 0
    ):
        return _result(
            "EVIDENCE_REQUIRED",
            "COLLECT_MORE_EVIDENCE",
            ["host_test_evidence_absent"],
            policy,
        )

    if evidence["host_tests_failed"] != 0:
        return _result("AMBIGUOUS", None, ["host_tests_failed"], policy)

    if evidence["evidence_scope"] == "host_model":
        return _result("PASS_HOST_MODEL", None, [], policy)
    return _result("PASS_FIXED", None, [], policy)
