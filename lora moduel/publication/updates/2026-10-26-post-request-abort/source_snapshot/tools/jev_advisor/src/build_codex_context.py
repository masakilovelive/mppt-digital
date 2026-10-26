"""Build a bounded, hashed review package only for the Codex route."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .evaluate_run import FINAL_ACTION_SCHEMA_VERSION
from .policy_gate import (
    get_action,
    validate_action_policy,
    validate_decision_input,
    verify_source_manifest,
)


_MAX_FILE_BYTES = 2_000_000
_MAX_TOTAL_BYTES = 10_000_000
_RAW_LOG_SUFFIXES = frozenset({".log", ".tlog", ".trace", ".raw", ".bin", ".csv"})
_FINAL_ACTION_FIELDS = frozenset(
    {
        "schema_version",
        "run_id",
        "source_hash",
        "policy_version",
        "deterministic_verdict",
        "deterministic_reasons",
        "verdict",
        "action_id",
        "cause_id",
        "confidence",
        "confidence_source",
        "execution_class",
        "jev_called",
        "model",
        "request_hash",
        "probabilities",
        "jev_suggested_action_id",
        "jev_usage",
        "gateway_cost",
        "generation_id",
        "jev_error_type",
        "jev_http_status",
        "jev_provider_error_type",
        "jev_provider_error_code",
        "shadow_only",
        "action_executed",
        "hardware_accessed",
        "com_opened",
        "firmware_flashed",
        "reasons",
    }
)


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )


def _inside(root: Path, candidate: Path) -> Path:
    resolved = candidate.resolve(strict=False)
    try:
        return resolved.relative_to(root)
    except ValueError as error:
        raise ValueError(f"context path escapes repository: {candidate}") from error


def build_context_package(
    repo_root: Path | str,
    decision_input: Mapping[str, Any],
    final_action: Mapping[str, Any],
    policy: Mapping[str, Any],
    output_directory: Path | str,
) -> dict[str, Any]:
    """Copy only the action allowlist and produce a content manifest.

    Missing optional files are recorded, never replaced with project-wide
    discovery. Raw logs, directories, symlinks outside the repository, and
    unbounded globs are rejected.
    """

    evidence = validate_decision_input(decision_input)
    validate_action_policy(policy)
    root = Path(repo_root).resolve(strict=True)
    verify_source_manifest(root, evidence)
    if not isinstance(final_action, Mapping):
        raise ValueError("final_action must be an object")
    unexpected = frozenset(final_action) - _FINAL_ACTION_FIELDS
    if unexpected:
        raise ValueError("final_action contains unexpected fields")
    if final_action.get("action_id") != "CODE_REVIEW_REQUIRED":
        raise ValueError("Codex context is allowed only for CODE_REVIEW_REQUIRED")
    expected_action_values = {
        "schema_version": FINAL_ACTION_SCHEMA_VERSION,
        "run_id": evidence["run_id"],
        "source_hash": evidence["source_hash"],
        "policy_version": policy["policy_version"],
        "cause_id": get_action(policy, "CODE_REVIEW_REQUIRED")["cause_id"],
        "shadow_only": True,
        "action_executed": False,
        "hardware_accessed": False,
        "com_opened": False,
        "firmware_flashed": False,
    }
    for name, expected in expected_action_values.items():
        if final_action.get(name) != expected:
            raise ValueError(f"final_action is not bound to this run: {name}")
    action = get_action(policy, "CODE_REVIEW_REQUIRED")
    allowlist = action["context_allowlist"]
    maximum = policy.get("context_limits", {}).get("max_optional_files")
    if isinstance(maximum, bool) or not isinstance(maximum, int) or maximum < 1:
        raise ValueError("invalid context file limit")
    if len(allowlist) > maximum:
        raise ValueError("context allowlist exceeds the policy file limit")

    output = Path(output_directory).resolve(strict=False)
    if output.exists():
        raise FileExistsError(f"context output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    selected: list[tuple[Path, Path]] = []
    missing: list[str] = []
    total_bytes = 0
    for template in allowlist:
        if not isinstance(template, str) or any(char in template for char in "*?[]"):
            raise ValueError("context allowlist must contain explicit relative paths")
        relative_text = template.replace("<run_id>", evidence["run_id"])
        relative = Path(relative_text)
        if relative.is_absolute():
            raise ValueError("context allowlist path must be relative")
        relative_resolved = _inside(root, root / relative)
        if relative_resolved.suffix.lower() in _RAW_LOG_SUFFIXES:
            raise ValueError(f"raw log is forbidden in context: {relative_resolved}")
        source = root / relative_resolved
        if not source.exists():
            missing.append(relative_resolved.as_posix())
            continue
        if not source.is_file():
            raise ValueError(f"context path is not a file: {relative_resolved}")
        size = source.stat().st_size
        if size > _MAX_FILE_BYTES:
            raise ValueError(f"context file exceeds size limit: {relative_resolved}")
        total_bytes += size
        if total_bytes > _MAX_TOTAL_BYTES:
            raise ValueError("context package exceeds total size limit")
        selected.append((source, relative_resolved))

    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.tmp-", dir=str(output.parent))
    )
    files: list[dict[str, Any]] = []
    try:
        for source, relative in selected:
            destination = temporary / "files" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            digest = hashlib.sha256(destination.read_bytes()).hexdigest()
            files.append(
                {"path": relative.as_posix(), "sha256": digest, "bytes": source.stat().st_size}
            )

        decision_bytes = _json_bytes(evidence)
        final_action_bytes = _json_bytes(dict(final_action))
        metadata = {
            "schema_version": "r19-codex-context-1",
            "run_id": evidence["run_id"],
            "source_hash": evidence["source_hash"],
            "policy_version": policy["policy_version"],
            "action_id": "CODE_REVIEW_REQUIRED",
            "cause_id": final_action["cause_id"],
            "confidence": final_action.get("confidence"),
            "fixed_acceptance": dict(policy["fixed_acceptance"]),
            "source_manifest": evidence["source_manifest"],
            "files": files,
            "missing_allowlisted_files": missing,
            "context_complete": not missing,
            "generated_artifacts": [
                {
                    "path": "decision_input.json",
                    "sha256": hashlib.sha256(decision_bytes).hexdigest(),
                    "bytes": len(decision_bytes),
                },
                {
                    "path": "final_action.json",
                    "sha256": hashlib.sha256(final_action_bytes).hexdigest(),
                    "bytes": len(final_action_bytes),
                },
            ],
            "raw_logs_included": False,
            "project_wide_bundle": False,
        }
        manifest_bytes = _json_bytes(metadata)
        (temporary / "decision_input.json").write_bytes(decision_bytes)
        (temporary / "final_action.json").write_bytes(final_action_bytes)
        (temporary / "context_manifest.json").write_bytes(manifest_bytes)
        (temporary / "context_manifest.sha256").write_text(
            hashlib.sha256(manifest_bytes).hexdigest() + "\n", encoding="ascii"
        )
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return metadata
