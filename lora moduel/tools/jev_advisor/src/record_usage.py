"""Validate and append comparable Jev/Codex usage measurements."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
from collections.abc import Mapping
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .policy_gate import ACTION_IDS


MEASUREMENT_SCHEMA = "jev-token-eval-2"

_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SHA256 = re.compile(r"^[A-Fa-f0-9]{64}$")
_RFC3339 = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"
)
_TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "total_tokens",
    "jev_input_tokens",
    "jev_output_tokens",
    "retry_count",
)
_RAW_FIELDS = frozenset(
    {
        "measurement_schema",
        "run_id",
        "issue_id",
        "mode",
        "source_hash",
        "codex_model",
        "reasoning_effort",
        "codex_called",
        "jev_called",
        *_TOKEN_FIELDS,
        "action_id",
        "confidence",
        "route_correct",
        "accepted_fix",
        "human_adjudication_id",
        "adjudicated_at",
        "safety_violation",
        "elapsed_seconds",
        "jev_cost_usd",
        "usage_source",
        "jev_generation_id",
        "measured_at",
    }
)
_CALCULATED_FIELDS = frozenset(
    {
        "codex_credits",
        "rate_card_version",
        "rate_card_hash",
        "rate_card_source",
        "rate_card_retrieved_at",
    }
)
_RATE_CARD_FIELDS = frozenset(
    {"rate_card_version", "description", "source_url", "retrieved_at", "models"}
)
_MODEL_RATE_FIELDS = frozenset(
    {"input_per_million", "cached_input_per_million", "output_per_million"}
)
_MAX_INPUT_BYTES = 1_000_000


class MeasurementError(ValueError):
    """Raised for incomparable, inconsistent, or unpriced measurements."""


def _nonnegative_int(record: Mapping[str, Any], name: str) -> int:
    value = record.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MeasurementError(f"{name} must be a non-negative integer")
    return value


def _nonnegative_number(record: Mapping[str, Any], name: str) -> float:
    value = record.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise MeasurementError(f"{name} must be a finite non-negative number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise MeasurementError(f"{name} must be a finite non-negative number")
    return number


def _rate(value: Any, name: str) -> Decimal:
    if isinstance(value, bool):
        raise MeasurementError(f"invalid rate: {name}")
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as error:
        raise MeasurementError(f"invalid rate: {name}") from error
    if not result.is_finite() or result < 0:
        raise MeasurementError(f"invalid rate: {name}")
    return result


def _date_time(value: Any, name: str) -> str:
    if not isinstance(value, str) or not _RFC3339.fullmatch(value):
        raise MeasurementError(f"{name} must be an RFC 3339 date-time with timezone")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise MeasurementError(
            f"{name} must be an RFC 3339 date-time with timezone"
        ) from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise MeasurementError(f"{name} must include a timezone")
    return value


def _https_url(value: Any, name: str) -> str:
    if not isinstance(value, str) or len(value) > 2048:
        raise MeasurementError(f"{name} must be an HTTPS URL")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise MeasurementError(f"{name} must be an HTTPS URL without credentials")
    return value


def _canonical_hash(value: Mapping[str, Any]) -> str:
    try:
        encoded = json.dumps(
            dict(value),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise MeasurementError("rate card must contain canonical JSON values") from error
    return hashlib.sha256(encoded).hexdigest()


def normalize_openai_usage(usage: Mapping[str, Any]) -> dict[str, int]:
    """Convert raw OpenAI usage to the R19 non-cached input convention.

    OpenAI's raw ``input_tokens`` includes cached tokens. R19 stores that
    cached subset separately, so the normalized ``input_tokens`` is the
    non-cached remainder and the provider ``total_tokens`` is unchanged.
    """

    if not isinstance(usage, Mapping):
        raise MeasurementError("OpenAI usage must be an object")
    raw_input = _nonnegative_int(usage, "input_tokens")
    output = _nonnegative_int(usage, "output_tokens")
    total = _nonnegative_int(usage, "total_tokens")
    details = usage.get("input_tokens_details", {})
    if details is None:
        details = {}
    if not isinstance(details, Mapping):
        raise MeasurementError("input_tokens_details must be an object")
    cached = _nonnegative_int(details, "cached_tokens") if "cached_tokens" in details else 0
    if cached > raw_input:
        raise MeasurementError("cached_tokens cannot exceed raw input_tokens")
    if total != raw_input + output:
        raise MeasurementError("raw total_tokens must equal input_tokens + output_tokens")
    return {
        "input_tokens": raw_input - cached,
        "cached_input_tokens": cached,
        "output_tokens": output,
        "total_tokens": total,
    }


def _validate_nullable_id(value: Any, name: str, *, max_length: int = 128) -> None:
    if value is None:
        return
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise MeasurementError(f"{name} must be null or a non-empty string")


def _validate_measurement(
    record: Mapping[str, Any], *, calculated: bool
) -> dict[str, int]:
    if not isinstance(record, Mapping):
        raise MeasurementError("measurement must be an object")
    allowed = _RAW_FIELDS | (_CALCULATED_FIELDS if calculated else frozenset())
    unknown = sorted(set(record) - allowed)
    missing = sorted(allowed - set(record))
    if unknown:
        raise MeasurementError(f"unknown measurement fields: {', '.join(unknown)}")
    if missing:
        raise MeasurementError(f"missing measurement fields: {', '.join(missing)}")

    if record.get("measurement_schema") != MEASUREMENT_SCHEMA:
        raise MeasurementError("unsupported measurement schema")
    for name in ("run_id", "issue_id"):
        if not isinstance(record.get(name), str) or not _ID.fullmatch(record[name]):
            raise MeasurementError(f"invalid {name}")
    if record.get("mode") not in {"baseline_codex", "jev_hybrid"}:
        raise MeasurementError("invalid mode")
    if not isinstance(record.get("source_hash"), str) or not _SHA256.fullmatch(
        record["source_hash"]
    ):
        raise MeasurementError("source_hash must be a SHA-256 hex digest")
    if not isinstance(record.get("codex_model"), str) or not (
        1 <= len(record["codex_model"]) <= 128
    ):
        raise MeasurementError("codex_model is required")
    if not isinstance(record.get("reasoning_effort"), str) or not (
        1 <= len(record["reasoning_effort"]) <= 32
    ):
        raise MeasurementError("reasoning_effort is required")
    for name in ("codex_called", "jev_called", "safety_violation"):
        if not isinstance(record.get(name), bool):
            raise MeasurementError(f"{name} must be boolean")

    tokens = {name: _nonnegative_int(record, name) for name in _TOKEN_FIELDS}
    if tokens["total_tokens"] != (
        tokens["input_tokens"]
        + tokens["cached_input_tokens"]
        + tokens["output_tokens"]
    ):
        raise MeasurementError(
            "total_tokens must equal input_tokens + cached_input_tokens + output_tokens"
        )
    if not record["codex_called"] and any(
        tokens[name]
        for name in (
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "total_tokens",
        )
    ):
        raise MeasurementError("Codex token counts must be zero when not called")

    usage_source = record.get("usage_source")
    if usage_source not in {"api_exact", "dashboard_batch", "estimated"}:
        raise MeasurementError("invalid usage_source")
    action_id = record.get("action_id")
    confidence = record.get("confidence")
    generation_id = record.get("jev_generation_id")
    _validate_nullable_id(generation_id, "jev_generation_id", max_length=256)
    if record["jev_called"]:
        if (action_id is None) != (confidence is None):
            raise MeasurementError("Jev action and confidence must both be present or null")
        if usage_source == "api_exact":
            if action_id not in ACTION_IDS:
                raise MeasurementError("action_id is outside the closed R19 set")
            if confidence is None or _nonnegative_number(record, "confidence") > 1:
                raise MeasurementError("confidence must be in the range 0..1")
            if generation_id is None:
                raise MeasurementError("api_exact Jev usage requires jev_generation_id")
    else:
        if tokens["jev_input_tokens"] or tokens["jev_output_tokens"]:
            raise MeasurementError("Jev token counts must be zero when not called")
        if action_id is not None or confidence is not None or generation_id is not None:
            raise MeasurementError(
                "Jev action, confidence, and generation id must be null when not called"
            )
    if action_id is not None and action_id not in ACTION_IDS:
        raise MeasurementError("action_id is outside the closed R19 set")
    if confidence is not None and _nonnegative_number(record, "confidence") > 1:
        raise MeasurementError("confidence must be in the range 0..1")

    for name in ("route_correct", "accepted_fix"):
        if record.get(name) is not None and not isinstance(record[name], bool):
            raise MeasurementError(f"{name} must be boolean or null")
    adjudication_id = record.get("human_adjudication_id")
    adjudicated_at = record.get("adjudicated_at")
    _validate_nullable_id(adjudication_id, "human_adjudication_id")
    adjudicated = (
        record.get("route_correct") is not None
        or record.get("accepted_fix") is not None
    )
    if adjudicated:
        if adjudication_id is None or adjudicated_at is None:
            raise MeasurementError(
                "human adjudication id and time are required for quality judgments"
            )
        _date_time(adjudicated_at, "adjudicated_at")
    elif adjudication_id is not None or adjudicated_at is not None:
        raise MeasurementError(
            "human adjudication provenance requires a quality judgment"
        )

    _nonnegative_number(record, "elapsed_seconds")
    jev_cost = _nonnegative_number(record, "jev_cost_usd")
    if not record["jev_called"] and jev_cost != 0:
        raise MeasurementError("jev_cost_usd must be zero when Jev was not called")
    _date_time(record.get("measured_at"), "measured_at")

    if calculated:
        _nonnegative_number(record, "codex_credits")
        if not record["codex_called"] and record["codex_credits"] != 0:
            raise MeasurementError("codex_credits must be zero when Codex was not called")
        version = record.get("rate_card_version")
        if not isinstance(version, str) or not (1 <= len(version) <= 128):
            raise MeasurementError("rate_card_version is required")
        if not isinstance(record.get("rate_card_hash"), str) or not _SHA256.fullmatch(
            record["rate_card_hash"]
        ):
            raise MeasurementError("rate_card_hash must be a SHA-256 hex digest")
        _https_url(record.get("rate_card_source"), "rate_card_source")
        _date_time(record.get("rate_card_retrieved_at"), "rate_card_retrieved_at")

    return tokens


def _validate_rate_card(rate_card: Mapping[str, Any]) -> tuple[str, str, str, Mapping[str, Any]]:
    if not isinstance(rate_card, Mapping):
        raise MeasurementError("rate_card must be an object")
    unknown = sorted(set(rate_card) - _RATE_CARD_FIELDS)
    required = {"rate_card_version", "source_url", "retrieved_at", "models"}
    missing = sorted(required - set(rate_card))
    if unknown:
        raise MeasurementError(f"unknown rate card fields: {', '.join(unknown)}")
    if missing:
        raise MeasurementError(f"missing rate card fields: {', '.join(missing)}")
    version = rate_card.get("rate_card_version")
    if not isinstance(version, str) or not (1 <= len(version) <= 128):
        raise MeasurementError("rate card is missing a version")
    source = _https_url(rate_card.get("source_url"), "rate card source_url")
    retrieved_at = _date_time(rate_card.get("retrieved_at"), "rate card retrieved_at")
    models = rate_card.get("models")
    if not isinstance(models, Mapping):
        raise MeasurementError("rate card models must be an object")
    for model, rates in models.items():
        if not isinstance(model, str) or not model or not isinstance(rates, Mapping):
            raise MeasurementError("invalid rate card model entry")
        if set(rates) != _MODEL_RATE_FIELDS:
            raise MeasurementError(f"invalid rate fields for model: {model}")
        for field in _MODEL_RATE_FIELDS:
            _rate(rates[field], f"{model}.{field}")
    return version, source, retrieved_at, models


def calculate_measurement(
    record: Mapping[str, Any], rate_card: Mapping[str, Any]
) -> dict[str, Any]:
    """Reconcile normalized usage and calculate credits from a sourced rate card."""

    tokens = _validate_measurement(record, calculated=False)
    version, source, retrieved_at, models = _validate_rate_card(rate_card)
    model_rates = models.get(record["codex_model"])
    if not isinstance(model_rates, Mapping):
        raise MeasurementError("rate card does not contain codex_model")
    input_rate = _rate(model_rates.get("input_per_million"), "input_per_million")
    cached_rate = _rate(
        model_rates.get("cached_input_per_million"), "cached_input_per_million"
    )
    output_rate = _rate(model_rates.get("output_per_million"), "output_per_million")
    credits = (
        Decimal(tokens["input_tokens"]) * input_rate
        + Decimal(tokens["cached_input_tokens"]) * cached_rate
        + Decimal(tokens["output_tokens"]) * output_rate
    ) / Decimal(1_000_000)

    result = dict(record)
    result.update(
        {
            "rate_card_version": version,
            "rate_card_hash": _canonical_hash(rate_card),
            "rate_card_source": source,
            "rate_card_retrieved_at": retrieved_at,
            "codex_credits": float(credits),
        }
    )
    _validate_measurement(result, calculated=True)
    return result


def record_measurement(path: Path | str, measurement: Mapping[str, Any]) -> None:
    """Validate and append one complete JSON record with one O_APPEND write."""

    _validate_measurement(measurement, calculated=True)
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        encoded = (
            json.dumps(
                dict(measurement),
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise MeasurementError("measurement must contain canonical JSON values") from error
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_BINARY", 0),
        0o600,
    )
    try:
        written = os.write(descriptor, encoded)
        if written != len(encoded):
            raise OSError("short JSONL append")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read_json_object(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > _MAX_INPUT_BYTES:
            raise MeasurementError(f"JSON input exceeds size limit: {path}")
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MeasurementError(f"cannot read JSON object {path}: {error}") from error
    if not isinstance(value, dict):
        raise MeasurementError(f"JSON input must be an object: {path}")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate, price, and append one R19 token measurement."
    )
    parser.add_argument("--measurement", required=True, type=Path)
    parser.add_argument("--rate-card", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        measurement = calculate_measurement(
            _read_json_object(args.measurement), _read_json_object(args.rate_card)
        )
        record_measurement(args.output, measurement)
    except Exception as error:
        print(
            f"JEV_TOKEN_MEASUREMENT_ERROR {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        return 2
    print(
        "JEV_TOKEN_MEASUREMENT RECORDED "
        f"run_id={measurement['run_id']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
