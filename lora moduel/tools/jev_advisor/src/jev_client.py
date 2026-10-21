"""Dependency-free client for Vercel AI Gateway's evaluation endpoint."""

from __future__ import annotations

import json
import math
import os
import re
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from typing import Any


JEV_EVALUATE_ENDPOINT = "https://ai-gateway.vercel.sh/v1/evaluate"
_MAX_RESPONSE_BYTES = 1_000_000
_MAX_REQUEST_BYTES = 1_000_000
_MAX_ERROR_RESPONSE_BYTES = 16_384
_ERROR_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")


def _bounded_http_status(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if not 100 <= value <= 599:
        return None
    return value


def _bounded_error_token(value: object) -> str | None:
    if not isinstance(value, str) or _ERROR_TOKEN.fullmatch(value) is None:
        return None
    return value


def _http_diagnostics(
    status: object, raw: bytes
) -> tuple[int | None, str | None, str | None]:
    bounded_status = _bounded_http_status(status)
    if len(raw) > _MAX_ERROR_RESPONSE_BYTES:
        return bounded_status, None, None
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return bounded_status, None, None
    if not isinstance(parsed, Mapping):
        return bounded_status, None, None
    error = parsed.get("error")
    if not isinstance(error, Mapping):
        return bounded_status, None, None
    return (
        bounded_status,
        _bounded_error_token(error.get("type")),
        _bounded_error_token(error.get("code")),
    )


def _read_http_error(
    error: urllib.error.HTTPError,
) -> tuple[int | None, str | None, str | None]:
    try:
        try:
            raw = error.read(_MAX_ERROR_RESPONSE_BYTES + 1)
        except (OSError, ValueError):
            raw = b""
        return _http_diagnostics(error.code, raw)
    finally:
        error.close()


class JevGatewayError(RuntimeError):
    """A bounded Jev request could not produce a usable JSON response."""

    def __init__(
        self,
        message: str,
        *,
        http_status: int | None = None,
        provider_error_type: str | None = None,
        provider_error_code: str | None = None,
    ) -> None:
        super().__init__(message)
        self.http_status = _bounded_http_status(http_status)
        self.provider_error_type = _bounded_error_token(provider_error_type)
        self.provider_error_code = _bounded_error_token(provider_error_code)


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        raise urllib.error.HTTPError(
            req.full_url, code, "Jev evaluation redirect refused", headers, fp
        )


class JevGatewayClient:
    """Callable one-request client; it never retries or logs credentials."""

    def __init__(
        self,
        api_key: str | None = None,
        *,
        timeout_seconds: float = 20.0,
        opener: Callable[..., Any] | None = None,
    ):
        if (
            isinstance(timeout_seconds, bool)
            or not isinstance(timeout_seconds, (int, float))
            or not math.isfinite(float(timeout_seconds))
            or float(timeout_seconds) <= 0
        ):
            raise ValueError("timeout_seconds must be finite and greater than zero")
        self._api_key = api_key
        self._timeout_seconds = float(timeout_seconds)
        self._opener = opener or urllib.request.build_opener(_NoRedirectHandler()).open

    def __call__(self, payload: dict[str, Any]) -> Mapping[str, Any]:
        api_key = self._api_key or os.environ.get("AI_GATEWAY_API_KEY")
        if not api_key:
            raise JevGatewayError("AI_GATEWAY_API_KEY is not configured")
        encoded = json.dumps(
            payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
        if len(encoded) > _MAX_REQUEST_BYTES:
            raise JevGatewayError("Jev evaluation request exceeded the size limit")
        request = urllib.request.Request(
            JEV_EVALUATE_ENDPOINT,
            data=encoded,
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "vc-lora-r19-jev-shadow/1",
            },
        )
        http_failure: tuple[int | None, str | None, str | None] | None = None
        raw = b""
        try:
            with self._opener(request, timeout=self._timeout_seconds) as response:
                status = getattr(response, "status", 200)
                if isinstance(status, int) and not 200 <= status < 300:
                    try:
                        error_raw = response.read(_MAX_ERROR_RESPONSE_BYTES + 1)
                    except (OSError, ValueError):
                        error_raw = b""
                    http_failure = _http_diagnostics(status, error_raw)
                else:
                    raw = response.read(_MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            http_failure = _read_http_error(error)
        except JevGatewayError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise JevGatewayError("Jev evaluation request failed") from error
        if http_failure is not None:
            status, provider_error_type, provider_error_code = http_failure
            raise JevGatewayError(
                "Jev evaluation returned a non-success status",
                http_status=status,
                provider_error_type=provider_error_type,
                provider_error_code=provider_error_code,
            )
        if len(raw) > _MAX_RESPONSE_BYTES:
            raise JevGatewayError("Jev evaluation response exceeded the size limit")
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise JevGatewayError("Jev evaluation response was not valid JSON") from error
        if not isinstance(parsed, Mapping):
            raise JevGatewayError("Jev evaluation response must be an object")
        return parsed
