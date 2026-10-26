# R19 Jev diagnostic advisor — Phase A

This directory implements the PC-side, shadow-only portion of
`Jev_Integration_and_Token_Measurement_Spec_R19.md`.

## Current boundary

- Local deterministic rules own PASS, FAIL, evidence requirements, and safety stops.
- Jev is considered only when the local result is `AMBIGUOUS`.
- Jev selects one ID from the eight-action closed catalog. It cannot return source
  code, change an acceptance threshold, change authorization, or execute an action.
- Phase A records a proposed route only. Every result fixes
  `action_executed=false`, `hardware_accessed=false`, `com_opened=false`, and
  `firmware_flashed=false`.
- No firmware, TDD state machine, MAVLink path, COM port, E220 setting, or Mission
  Planner connection is imported or controlled by this tool.
- `host` evidence can produce only `PASS_HOST_MODEL`; only `hil` evidence bound to
  `hil_physical` scope can produce the physical `PASS_FIXED` verdict.

The design document illustrates TypeScript filenames. This repository has no
Node/npm toolchain, so the Phase-A implementation uses the existing Python 3.12
runtime and only the standard library. The component boundaries and JSON contracts
remain the same.

## Fixed R19 checks

The closed input requires enough evidence to decide all fixed conditions:

- exact 932 unique parameters and no missing, duplicate, or out-of-order item;
- completion at or below 30,000 ms;
- first, maximum, and post-run Heartbeat gaps at or below 2,500 ms;
- at least one measured Heartbeat sample and strictly positive measured timings;
- zero sanitizer, CRC, parser, partial-frame, and control-leakage errors;
- rejected/zero-write identity, standard Grant handoff, direction guard, final
  VCB1 physical tail, and VCTA physical drain evidence;
- bounded failed-test IDs whose count exactly equals `host_tests_failed`;
- explicit safety-request flags.
- an explicit source manifest whose canonical hash and current file bytes both
  match the decision input.

An absent or inconsistent field is an input error, not an assumed zero. A fixed
FAIL is never sent to Jev for conversion to PASS.

## Run offline shadow evaluation

The default command performs no network call:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools\run_jev_phase_a_shadow.ps1 `
  -DecisionInputPath <r19-decision-input.json>
```

It creates a new, non-overwriting directory under
`runs/decision/<run_id>/` containing:

```text
input.json
deterministic_result.json
jev_result.json
final_action.json
summary.json
```

For `CODE_REVIEW_REQUIRED`, the run also contains `codex_context/` with generated
input/action hashes, a bounded allowlist manifest, and a manifest SHA-256 sidecar.
The command reports `ARTIFACTS_WRITTEN verdict=...`; successful artifact creation
is deliberately not printed as an engineering `PASS`.

For an ambiguous input, offline mode records `JEV_DISABLED` and
`COLLECT_MORE_EVIDENCE`. Fixed local PASS/FAIL/STOP results do not need Jev.

## Optional one-request Jev shadow evaluation

Only after configuring a Vercel AI Gateway key, explicitly add `-EnableNetwork`:

```powershell
$env:AI_GATEWAY_API_KEY = '<secret>'
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools\run_jev_phase_a_shadow.ps1 `
  -DecisionInputPath <r19-decision-input.json> `
  -EnableNetwork
```

The client makes at most one `POST https://ai-gateway.vercel.sh/v1/evaluate`
request with model `typesafe-ai/jev`. It sends only the validated bounded JSON,
forces the TypeSafe provider and requests zero-data-retention. A timeout, provider
rejection or redirect, malformed response, model mismatch, an incomplete or
non-normalized eight-choice probability distribution, missing usage, or missing
finite cost/generation metadata falls back to `COLLECT_MORE_EVIDENCE`.
For an HTTP rejection, artifacts retain only a numeric status and optional
64-character ASCII identifiers from `error.type` and `error.code`. The response
message/body, response headers, and credentials are never saved.

The selected choice's value in `answers.route.probabilities` is the confidence used
for this HTTP response shape. It is never inferred from free text.

## Validation status (2026-09-24)

- One live shadow smoke request succeeded with model `typesafe-ai/jev`, the
  TypeSafe-only route, and the request option `zeroDataRetention=true`. It used
  synthetic host-model input and recorded an advisory route only; it is not an R19 physical-acceptance
  result. The byte-identical artifacts are sealed under
  `runs/validation/R19-JEV-LIVE-SMOKE-001/R19-JEV-DRY/`.
- Saved R19 summaries were byte-hashed into
  `runs/validation/R19-JEV-REAL-INPUT-001/input.json` and evaluated offline under
  `runs/decision/R19-REAL-OFFLINE-001/`. The replay source is
  `OFFLINE_SELF_TEST` with `test_scope=host` and `evidence_scope=host_model`, not
  full physical HIL. It records 932/932 parameters, 23,575 ms completion, and a
  1,000 ms maximum Heartbeat gap, but unresolved physical-evidence states and one
  host-suite failure produce `EVIDENCE_REQUIRED`; Jev was not called for this run.
- The exact tools, four source snapshots, offline result, and verification output
  are sealed under `runs/validation/R19-JEV-PHASE-A-V3-001/`. Its software
  validation is PASS while its separate engineering verdict remains
  `EVIDENCE_REQUIRED`.
- The Codex-only versus hybrid token, cost, and treatment-quality comparison remains
  pending exact paired provider usage receipts, a configured sourced rate card, and
  human-adjudication provenance. No saving is claimed.

## Codex context and usage accounting

`build_codex_context.py` accepts only `CODE_REVIEW_REQUIRED`. It substitutes the
run ID into a maximum-12-file explicit allowlist, rejects path escape and globs,
records missing optional files, hashes copied files, and excludes raw logs and
project-wide bundles.

`record_usage.py` requires a versioned external rate card with source URL,
retrieval time, and a canonical hash. The checked-in
`policies/codex_rate_cards.json` is intentionally unconfigured; rates must be added
from the authoritative source at measurement time. OpenAI raw usage reports cached
tokens inside raw `input_tokens`; `normalize_openai_usage()` converts that response
to the design document's disjoint stored fields:

```text
stored input_tokens = raw input_tokens - raw cached_tokens
stored total_tokens = stored input_tokens + cached_input_tokens + output_tokens
```

Thus the design document's total formula remains valid after normalization; cached
input is not counted twice. Exact API measurements also require a provider receipt,
and quality labels require human-adjudication provenance. No token or cost saving is
claimed until comparable baseline/hybrid records exist.

After completing a raw measurement record and a sourced rate card, validate,
price, and append it with:

```powershell
py -3.12 -m tools.jev_advisor.src.record_usage `
  --measurement <raw-measurement.json> `
  --rate-card <configured-rate-card.json> `
  --output <token-usage.jsonl>
```

## Verification

```powershell
py -3.12 tests\test_jev_advisor.py -v
py -3.12 tests\test_jev_client.py -v
py -3.12 tests\test_jev_measurement.py -v
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tests\host\check_jev_phase_a_artifacts_contract.ps1
```

The unit suite uses a recorded fake Jev response and does not contact an API. The
live smoke described above was a separate, explicitly network-enabled invocation.
