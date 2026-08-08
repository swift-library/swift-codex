#!/usr/bin/env python3
"""Generate or verify the deterministic public API baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parent.parent
API_SCRATCH_DIRECTORY = REPOSITORY_ROOT / ".build" / "public-api"
SYMBOL_GRAPH_DIRECTORY = API_SCRATCH_DIRECTORY / "out" / "symbolgraph"
BASELINE_PATH = REPOSITORY_ROOT / "API" / "PublicAPI.json"
PUBLIC_MODULES = (
    "Codex",
    "CodexAppServerClient",
    "CodexAppServerHummingbird",
    "CodexAppServerNIO",
    "CodexAppServerProtocol",
    "CodexAppServerRuntime",
    "CodexAppServerStdio",
    "CodexAppServerURLSession",
    "CodexAppServerVapor",
    "CodexExec",
    "CodexMCP",
)


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def selected_symbol(symbol: dict[str, object]) -> dict[str, object]:
    selected: dict[str, object] = {}
    for key in (
        "identifier",
        "kind",
        "pathComponents",
        "declarationFragments",
        "functionSignature",
        "swiftExtension",
        "availability",
    ):
        if key in symbol:
            selected[key] = symbol[key]
    return selected


def selected_relationship(relationship: dict[str, object]) -> dict[str, object]:
    return {
        key: relationship[key]
        for key in ("source", "target", "kind", "targetFallback", "swiftConstraints")
        if key in relationship
    }


def graph_paths(module: str) -> list[pathlib.Path]:
    direct = SYMBOL_GRAPH_DIRECTORY / f"{module}.symbols.json"
    extensions = sorted(SYMBOL_GRAPH_DIRECTORY.glob(f"{module}@*.symbols.json"))
    return [direct, *extensions]


def module_baseline(module: str) -> dict[str, object]:
    symbols: list[dict[str, object]] = []
    relationships: list[dict[str, object]] = []
    for path in graph_paths(module):
        if not path.is_file():
            raise RuntimeError(f"missing symbol graph: {path.relative_to(REPOSITORY_ROOT)}")
        graph = json.loads(path.read_text(encoding="utf-8"))
        if graph.get("module", {}).get("name") != module:
            raise RuntimeError(f"unexpected module name in {path.name}")
        symbols.extend(selected_symbol(symbol) for symbol in graph.get("symbols", []))
        relationships.extend(
            selected_relationship(relationship)
            for relationship in graph.get("relationships", [])
        )

    symbols.sort(key=lambda value: canonical_json(value))
    relationships.sort(key=lambda value: canonical_json(value))
    payload = {"symbols": symbols, "relationships": relationships}
    return {
        "name": module,
        "symbol_count": len(symbols),
        "relationship_count": len(relationships),
        "api_sha256": hashlib.sha256(canonical_json(payload)).hexdigest(),
    }


def build_baseline() -> dict[str, object]:
    subprocess.run(
        [
            "swift",
            "package",
            "--scratch-path",
            str(API_SCRATCH_DIRECTORY),
            "dump-symbol-graph",
            "--skip-synthesized-members",
            "--skip-inherited-docs",
            "--minimum-access-level",
            "public",
        ],
        cwd=REPOSITORY_ROOT,
        check=True,
    )
    return {
        "schema_version": 1,
        "generator": {
            "command": "swift package dump-symbol-graph",
            "minimum_access_level": "public",
            "skip_inherited_docs": True,
            "skip_synthesized_members": True,
        },
        "modules": [module_baseline(module) for module in PUBLIC_MODULES],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--update",
        action="store_true",
        help="replace API/PublicAPI.json with the current public API",
    )
    arguments = parser.parse_args()

    baseline = build_baseline()
    serialized = json.dumps(baseline, indent=2, sort_keys=True) + "\n"
    if arguments.update:
        BASELINE_PATH.parent.mkdir(parents=True, exist_ok=True)
        BASELINE_PATH.write_text(serialized, encoding="utf-8")
        print(f"Updated {BASELINE_PATH.relative_to(REPOSITORY_ROOT)}")
        return 0

    if not BASELINE_PATH.is_file():
        print("Public API baseline is missing; run with --update.", file=sys.stderr)
        return 1
    expected = BASELINE_PATH.read_text(encoding="utf-8")
    if expected != serialized:
        print(
            "Public API differs from API/PublicAPI.json; review the API change "
            "and run Scripts/verify-public-api.py --update if intentional.",
            file=sys.stderr,
        )
        return 1
    print("Public API baseline verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
