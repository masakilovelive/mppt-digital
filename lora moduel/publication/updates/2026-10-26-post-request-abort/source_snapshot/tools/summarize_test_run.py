#!/usr/bin/env python3
"""Aggregate per-test VC LoRa summary.json files without third-party modules."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def is_ctest_summary(path: Path, item: object) -> bool:
    """Return true only for the canonical per-CTest summary directory."""
    if not isinstance(item, dict):
        return False
    return (
        isinstance(item.get("test"), str)
        and path.parent.name == item.get("test")
        and type(item.get("seed")) is int
        and item.get("result") in {"PASS", "XFAIL", "FAIL"}
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="?", type=Path, default=Path("runs"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    summaries = []
    for path in sorted(args.runs.glob("*/summary.json")):
        with path.open("r", encoding="utf-8") as stream:
            item = json.load(stream)
        # The runs directory also contains build/sanitizer manifests.  Those
        # are evidence artifacts, not CTest cases, and deliberately have no
        # integer seed.
        if is_ctest_summary(path, item):
            summaries.append(item)

    result = {
        "total": len(summaries),
        "passed": sum(item.get("result") == "PASS" for item in summaries),
        "xfailed": sum(item.get("result") == "XFAIL" for item in summaries),
        "failed": sum(
            item.get("result") not in {"PASS", "XFAIL"} for item in summaries
        ),
        "seed": sorted({item.get("seed") for item in summaries}),
        "tests": [
            {"test": item.get("test"), "result": item.get("result")}
            for item in summaries
        ],
    }
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if result["failed"] == 0 and result["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
