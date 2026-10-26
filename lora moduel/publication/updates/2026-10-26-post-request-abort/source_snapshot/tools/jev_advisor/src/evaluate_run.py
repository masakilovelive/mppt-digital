"""One-shot Jev shadow routing after deterministic R19 policy evaluation."""

from __future__ import annotations

import hashlib
import json
import math
from collections.abc import Callable, Mapping
from decimal import Decimal, InvalidOperation
from typing import Any

from .jev_client import JevGatewayError
from .policy_gate import (
    ACTION_IDS,
    evaluate_fixed_policy,
    get_action,
    validate_action_policy,
    validate_decision_input,
)


JEV_MODEL = "typesafe-ai/jev"
FINAL_ACTION_SCHEMA_VERSION = "r19-jev-final-action-1"


class JevResponseError(ValueError):
    """Raised when a provider response is not a bounded typed choice."""


def _shadow_fields() -> dict[str, bool]:
    return {
        "shadow_only": True,
        "action_executed": False,
        "hardware_accessed": False,
        "com_opened": False,
        "firmware_flashed": False,
    }


def build_jev_payload(
    evidence: Mapping[str, Any], policy: Mapping[str, Any]
) -> dict[str, Any]:
    """Build the single closed-choice request accepted by Phase A."""

    validated = validate_decision_input(evidence)
    validate_action_policy(policy)
    criteria = {
        action_id: str(get_action(policy, action_id)["description"])
        for action_id in sorted(ACTION_IDS)
    }
    return {
        "model": JEV_MODEL,
        "state": validated,
        "questions": {
            "route": {
                "type": "choice",
                "instructions": (
                    "Select exactly one bounded diagnostic next action. "
                    "Do not change R19 acceptance, authorization, hardware, "
                    "communication parameters, or a deterministic verdict."
                ),
                "criteria": criteria,
            }
        },
        "providerOptions": {
            "gateway": {"zeroDataRetention": True, "only": ["typesafe-ai"]}
        },
    }


def _canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _nonnegative_usage(response: Mapping[str, Any]) -> dict[str, int]:
    usage = response.get("usage")
    if usage is None:
        raise JevResponseError("usage is required for an accepted Jev response")
    if not isinstance(usage, Mapping):
        raise JevResponseError("usage must be an object when present")
    result: dict[str, int] = {}
    for source, target in (("inputTokens", "input_tokens"), ("outputTokens", "output_tokens")):
        value = usage.get(source)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise JevResponseError(f"usage.{source} must be a non-negative integer")
        result[target] = value
    return result


def _parse_response(response: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(response, Mapping):
        raise JevResponseError("Jev response must be an object")
    if response.get("model") != JEV_MODEL:
        raise JevResponseError("unexpected resolved model")
    answers = response.get("answers")
    if not isinstance(answers, Mapping):
        raise JevResponseError("missing answers object")
    route = answers.get("route")
    if not isinstance(route, Mapping) or route.get("type") != "choice":
        raise JevResponseError("route answer is not a typed choice")
    choice = route.get("choice")
    if not isinstance(choice, str) or choice not in ACTION_IDS:
        raise JevResponseError("route choice is outside the closed action set")
    probabilities = route.get("probabilities")
    if not isinstance(probabilities, Mapping) or frozenset(probabilities) != ACTION_IDS:
        raise JevResponseError("probabilities must contain the exact closed action set")
    raw_confidence = probabilities[choice]
    if isinstance(raw_confidence, bool) or not isinstance(raw_confidence, (int, float)):
        raise JevResponseError("selected choice probability is not numeric")
    confidence = float(raw_confidence)
    if not math.isfinite(confidence) or not 0 <= confidence <= 1:
        raise JevResponseError("selected choice probability is outside 0..1")
    normalized_probabilities: dict[str, float] = {}
    for action_id, probability in probabilities.items():
        if isinstance(probability, bool) or not isinstance(probability, (int, float)):
            raise JevResponseError("choice probability is not numeric")
        normalized = float(probability)
        if not math.isfinite(normalized) or not 0 <= normalized <= 1:
            raise JevResponseError("choice probability is outside 0..1")
        normalized_probabilities[action_id] = normalized
    if not math.isclose(
        sum(normalized_probabilities.values()), 1.0, rel_tol=0.0, abs_tol=0.01
    ):
        raise JevResponseError("choice probabilities do not sum to one")

    parsed: dict[str, Any] = {
        "choice": choice,
        "confidence": confidence,
        "confidence_source": "answers.route.probabilities[selected_choice]",
        "probabilities": normalized_probabilities,
        "usage": _nonnegative_usage(response),
        "model": JEV_MODEL,
    }
    metadata = response.get("providerMetadata")
    if not isinstance(metadata, Mapping) or not isinstance(
        metadata.get("gateway"), Mapping
    ):
        raise JevResponseError("providerMetadata.gateway is required")
    gateway = metadata["gateway"]
    cost = gateway.get("cost")
    if isinstance(cost, bool) or not isinstance(cost, (str, int, float)):
        raise JevResponseError("gateway cost must be numeric")
    try:
        decimal_cost = Decimal(str(cost))
    except InvalidOperation as error:
        raise JevResponseError("gateway cost is invalid") from error
    if not decimal_cost.is_finite() or decimal_cost < 0:
        raise JevResponseError("gateway cost must be finite and non-negative")
    generation_id = gateway.get("generationId")
    if not isinstance(generation_id, str) or not generation_id.strip():
        raise JevResponseError("gateway generationId is required")
    parsed["gateway_cost"] = str(decimal_cost)
    parsed["generation_id"] = generation_id
    return parsed


def _base_result(
    evidence: Mapping[str, Any],
    policy: Mapping[str, Any],
    fixed: Mapping[str, Any],
    *,
    verdict: str,
    action_id: str | None,
    execution_class: str,
    jev_called: bool,
    model: str | None = None,
    request_hash: str | None = None,
) -> dict[str, Any]:
    cause_id = None
    if action_id is not None:
        cause_id = get_action(policy, action_id)["cause_id"]
    return {
        "schema_version": FINAL_ACTION_SCHEMA_VERSION,
        "run_id": evidence["run_id"],
        "source_hash": evidence["source_hash"],
        "policy_version": policy["policy_version"],
        "deterministic_verdict": fixed["verdict"],
        "deterministic_reasons": list(fixed.get("reasons", [])),
        "verdict": verdict,
        "action_id": action_id,
        "cause_id": cause_id,
        "confidence": None,
        "confidence_source": None,
        "execution_class": execution_class,
        "jev_called": jev_called,
        "model": model,
        "request_hash": request_hash,
        "probabilities": None,
        "jev_suggested_action_id": None,
        "jev_usage": None,
        "gateway_cost": None,
        "generation_id": None,
        "jev_error_type": None,
        "jev_http_status": None,
        "jev_provider_error_type": None,
        "jev_provider_error_code": None,
        **_shadow_fields(),
    }


def evaluate_run(
    item: Mapping[str, Any],
    policy: Mapping[str, Any],
    client: Callable[[dict[str, Any]], Mapping[str, Any]] | None,
) -> dict[str, Any]:
    """Evaluate one run without ever executing the selected action."""

    evidence = validate_decision_input(item)
    validate_action_policy(policy)
    fixed = evaluate_fixed_policy(evidence, policy)
    if fixed["verdict"] != "AMBIGUOUS":
        result = _base_result(
            evidence,
            policy,
            fixed,
            verdict=str(fixed["verdict"]),
            action_id=fixed.get("action_id"),
            execution_class="FIXED_LOCAL",
            jev_called=False,
        )
        result["reasons"] = list(fixed.get("reasons", []))
        return result

    if client is None:
        return _base_result(
            evidence,
            policy,
            fixed,
            verdict="ADVISORY_FALLBACK",
            action_id="COLLECT_MORE_EVIDENCE",
            execution_class="JEV_DISABLED",
            jev_called=False,
        )
    payload = build_jev_payload(evidence, policy)
    request_hash = _canonical_hash(payload)
    try:
        parsed = _parse_response(client(payload))
    except Exception as error:  # Provider failures must always fail closed.
        result = _base_result(
            evidence,
            policy,
            fixed,
            verdict="ADVISORY_FALLBACK",
            action_id="COLLECT_MORE_EVIDENCE",
            execution_class="API_FALLBACK",
            jev_called=True,
            model=JEV_MODEL,
            request_hash=request_hash,
        )
        result["jev_error_type"] = type(error).__name__
        if isinstance(error, JevGatewayError):
            result["jev_http_status"] = error.http_status
            result["jev_provider_error_type"] = error.provider_error_type
            result["jev_provider_error_code"] = error.provider_error_code
        return result

    suggested_action = parsed["choice"]
    confidence = parsed["confidence"]
    action_id = suggested_action
    verdict = "ADVISORY"
    if suggested_action == "STOP_SAFETY_CONDITION":
        verdict = "STOP"
        execution_class = "SAFETY_STOP"
    elif confidence < policy["confidence_routing"]["low"]["maximum_exclusive"]:
        action_id = "COLLECT_MORE_EVIDENCE"
        execution_class = "INSUFFICIENT_CONFIDENCE"
    elif confidence < policy["confidence_routing"]["high"]["minimum"]:
        execution_class = "REVIEW_REQUIRED"
    elif get_action(policy, action_id).get("future_high_confidence_candidate"):
        execution_class = "SHADOW_AUTO_ELIGIBLE"
    else:
        execution_class = "REVIEW_REQUIRED"

    result = _base_result(
        evidence,
        policy,
        fixed,
        verdict=verdict,
        action_id=action_id,
        execution_class=execution_class,
        jev_called=True,
        model=parsed["model"],
        request_hash=request_hash,
    )
    result.update(
        {
            "jev_suggested_action_id": suggested_action,
            "confidence": confidence,
            "confidence_source": parsed["confidence_source"],
            "probabilities": parsed["probabilities"],
            "jev_usage": parsed["usage"],
            "gateway_cost": parsed["gateway_cost"],
            "generation_id": parsed["generation_id"],
        }
    )
    return result
