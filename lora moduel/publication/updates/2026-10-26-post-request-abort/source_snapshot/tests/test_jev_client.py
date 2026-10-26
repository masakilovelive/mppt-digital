#!/usr/bin/env python3
"""Network-free contract tests for the one-request Jev gateway client."""

from __future__ import annotations

import io
import json
import sys
import unittest
import urllib.error
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from tools.jev_advisor.src.evaluate_run import JEV_MODEL
from tools.jev_advisor.src.jev_client import (
    JEV_EVALUATE_ENDPOINT,
    JevGatewayClient,
    JevGatewayError,
)


class _Response:
    def __init__(self, body: bytes, *, status: int = 200) -> None:
        self._body = body
        self.status = status

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self, _: int) -> bytes:
        return self._body


class JevGatewayClientTests(unittest.TestCase):
    def test_exactly_one_post_has_bounded_provider_options(self) -> None:
        calls: list[tuple[object, float]] = []

        def opener(request: object, *, timeout: float) -> _Response:
            calls.append((request, timeout))
            return _Response(b'{"model":"typesafe-ai/jev"}')

        payload = {
            "model": JEV_MODEL,
            "questions": {"route": {"type": "choice", "criteria": {"A": "a"}}},
            "providerOptions": {
                "gateway": {"zeroDataRetention": True, "only": ["typesafe-ai"]}
            },
        }
        result = JevGatewayClient(
            "secret-test-key", timeout_seconds=4.5, opener=opener
        )(payload)

        self.assertEqual(JEV_MODEL, result["model"])
        self.assertEqual(1, len(calls))
        request, timeout = calls[0]
        self.assertEqual(4.5, timeout)
        self.assertEqual(JEV_EVALUATE_ENDPOINT, request.full_url)  # type: ignore[attr-defined]
        self.assertEqual("POST", request.get_method())  # type: ignore[attr-defined]
        self.assertEqual(
            "Bearer secret-test-key",
            request.get_header("Authorization"),  # type: ignore[attr-defined]
        )
        sent = json.loads(request.data.decode("utf-8"))  # type: ignore[attr-defined]
        self.assertEqual(payload, sent)

    def test_invalid_timeout_status_and_json_fail_closed(self) -> None:
        for timeout in (0, -1, float("inf"), float("nan"), True):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                JevGatewayClient("key", timeout_seconds=timeout)

        with self.assertRaises(JevGatewayError):
            JevGatewayClient(
                "key", opener=lambda *_args, **_kwargs: _Response(b"{}", status=302)
            )({})
        with self.assertRaises(JevGatewayError):
            JevGatewayClient(
                "key", opener=lambda *_args, **_kwargs: _Response(b"not-json")
            )({})

    def test_http_error_exposes_only_sanitized_bounded_diagnostics(self) -> None:
        calls = 0
        body = json.dumps(
            {
                "error": {
                    "type": "access_denied",
                    "code": "zdr_not_available",
                    "message": "private provider message secret-test-key",
                },
                "headers": {"Authorization": "Bearer secret-test-key"},
            }
        ).encode("utf-8")

        def opener(*_args: object, **_kwargs: object) -> _Response:
            nonlocal calls
            calls += 1
            raise urllib.error.HTTPError(
                JEV_EVALUATE_ENDPOINT,
                403,
                "private HTTP reason secret-test-key",
                {"Authorization": "Bearer secret-test-key"},
                io.BytesIO(body),
            )

        with self.assertRaises(JevGatewayError) as caught:
            JevGatewayClient("secret-test-key", opener=opener)({})

        error = caught.exception
        self.assertEqual(1, calls)
        self.assertEqual(403, error.http_status)
        self.assertEqual("access_denied", error.provider_error_type)
        self.assertEqual("zdr_not_available", error.provider_error_code)
        exposed = f"{error!s} {error!r} {vars(error)!r}"
        self.assertNotIn("private provider message", exposed)
        self.assertNotIn("private HTTP reason", exposed)
        self.assertNotIn("Authorization", exposed)
        self.assertNotIn("secret-test-key", exposed)
        self.assertIsNone(error.__cause__)
        self.assertIsNone(error.__context__)

    def test_http_error_rejects_unallowlisted_or_oversized_error_tokens(self) -> None:
        body = json.dumps(
            {
                "error": {
                    "type": "access denied with free text",
                    "code": "x" * 65,
                }
            }
        ).encode("utf-8")

        def opener(*_args: object, **_kwargs: object) -> _Response:
            raise urllib.error.HTTPError(
                JEV_EVALUATE_ENDPOINT, 403, "Forbidden", {}, io.BytesIO(body)
            )

        with self.assertRaises(JevGatewayError) as caught:
            JevGatewayClient("key", opener=opener)({})

        self.assertEqual(403, caught.exception.http_status)
        self.assertIsNone(caught.exception.provider_error_type)
        self.assertIsNone(caught.exception.provider_error_code)


if __name__ == "__main__":
    unittest.main()
