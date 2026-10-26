"""Command-line Phase-A runner for saved, bounded R19 evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from .evaluate_run import evaluate_run
from .build_codex_context import build_context_package
from .jev_client import JevGatewayClient
from .policy_gate import (
    evaluate_fixed_policy,
    load_action_policy,
    validate_decision_input,
    verify_source_manifest,
)


_MAX_INPUT_BYTES = 1_000_000


def _read_object(path: Path) -> dict[str, Any]:
    if path.stat().st_size > _MAX_INPUT_BYTES:
        raise ValueError("decision input exceeds the size limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read decision input: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("decision input must be a JSON object")
    return value


def _write_json(path: Path, value: Any) -> None:
    encoded = (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    path.write_bytes(encoded)


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_shadow(
    *,
    input_path: Path | str,
    output_root: Path | str,
    policy_path: Path | str,
    enable_network: bool = False,
    client: Callable[[dict[str, Any]], Mapping[str, Any]] | None = None,
    repo_root: Path | str | None = None,
) -> Path:
    """Evaluate one saved run and atomically publish record-only artifacts."""

    resolved_policy_path = Path(policy_path).resolve(strict=True)
    evidence = validate_decision_input(_read_object(Path(input_path)))
    policy = load_action_policy(resolved_policy_path)
    resolved_repo_root = (
        Path(repo_root).resolve(strict=True)
        if repo_root is not None
        else resolved_policy_path.parents[3]
    )
    verify_source_manifest(resolved_repo_root, evidence)
    fixed = evaluate_fixed_policy(evidence, policy)
    actual_client: Callable[[dict[str, Any]], Mapping[str, Any]] | None = None
    if enable_network:
        actual_client = client or JevGatewayClient()
    elif client is not None:
        raise ValueError("an API client requires enable_network=True")
    final = evaluate_run(evidence, policy, actual_client)

    destination_root = Path(output_root).resolve(strict=False)
    destination = destination_root / evidence["run_id"]
    if destination.exists():
        raise FileExistsError(f"decision run already exists: {destination}")
    destination_root.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(
            prefix=f".{evidence['run_id']}.tmp-", dir=str(destination_root)
        )
    )
    try:
        deterministic_result = {
            "schema_version": "r19-deterministic-result-1",
            "run_id": evidence["run_id"],
            "source_hash": evidence["source_hash"],
            "policy_version": policy["policy_version"],
            **fixed,
        }
        _write_json(temporary / "input.json", evidence)
        _write_json(temporary / "deterministic_result.json", deterministic_result)
        jev_result = {
            "schema_version": "r19-jev-provider-result-1",
            "run_id": evidence["run_id"],
            "source_hash": evidence["source_hash"],
            "policy_version": policy["policy_version"],
        }
        jev_result.update(
            {
                name: final.get(name)
                for name in (
                    "jev_called",
                    "jev_suggested_action_id",
                    "confidence",
                    "confidence_source",
                    "jev_usage",
                    "gateway_cost",
                    "generation_id",
                    "jev_error_type",
                    "jev_http_status",
                    "jev_provider_error_type",
                    "jev_provider_error_code",
                    "execution_class",
                    "model",
                    "request_hash",
                    "probabilities",
                )
            }
        )
        _write_json(temporary / "jev_result.json", jev_result)
        _write_json(temporary / "final_action.json", final)
        if final.get("action_id") == "CODE_REVIEW_REQUIRED":
            build_context_package(
                resolved_repo_root,
                evidence,
                final,
                policy,
                temporary / "codex_context",
            )
        artifact_hashes = {
            name: _sha256_file(temporary / name)
            for name in (
                "input.json",
                "deterministic_result.json",
                "jev_result.json",
                "final_action.json",
            )
        }
        input_schema_path = (
            resolved_repo_root
            / "tools"
            / "jev_advisor"
            / "schemas"
            / "r19_decision_input.schema.json"
        )
        _write_json(
            temporary / "summary.json",
            {
                "schema_version": "r19-jev-shadow-summary-2",
                "run_id": evidence["run_id"],
                "source_hash": evidence["source_hash"],
                "source_manifest": evidence["source_manifest"],
                "source_manifest_verified": True,
                "policy_version": policy["policy_version"],
                "policy_sha256": _sha256_file(resolved_policy_path),
                "input_schema_sha256": _sha256_file(input_schema_path),
                "test_scope": evidence["test_scope"],
                "evidence_scope": evidence["evidence_scope"],
                "shadow_only": True,
                "action_executed": False,
                "hardware_accessed": False,
                "com_opened": False,
                "firmware_flashed": False,
                "network_enabled": enable_network,
                "deterministic_verdict": fixed["verdict"],
                "final_verdict": final["verdict"],
                "final_action_id": final.get("action_id"),
                "execution_class": final["execution_class"],
                "request_hash": final.get("request_hash"),
                "artifact_sha256": artifact_hashes,
                "codex_context_created": final.get("action_id")
                == "CODE_REVIEW_REQUIRED",
            },
        )
        os.replace(temporary, destination)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return destination


def _parser() -> argparse.ArgumentParser:
    default_policy = Path(__file__).resolve().parents[1] / "policies" / "r19_actions.json"
    parser = argparse.ArgumentParser(
        description="Evaluate saved R19 evidence in shadow-only mode."
    )
    parser.add_argument("--input", required=True, type=Path, help="bounded input JSON")
    parser.add_argument(
        "--output-root", type=Path, default=Path("runs/decision"), help="new run parent"
    )
    parser.add_argument("--policy", type=Path, default=default_policy)
    parser.add_argument(
        "--enable-network",
        action="store_true",
        help="allow one Vercel Jev request for an ambiguous result",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        destination = run_shadow(
            input_path=args.input,
            output_root=args.output_root,
            policy_path=args.policy,
            enable_network=args.enable_network,
        )
    except Exception as error:
        print(f"JEV_PHASE_A_ERROR {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    summary = json.loads((destination / "summary.json").read_text(encoding="utf-8"))
    print(
        "JEV_PHASE_A_SHADOW ARTIFACTS_WRITTEN "
        f"verdict={summary['final_verdict']} output={destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
