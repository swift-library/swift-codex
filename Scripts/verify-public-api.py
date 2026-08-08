#!/usr/bin/env python3
"""Generate or verify the deterministic public API baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parent.parent
API_SCRATCH_DIRECTORY = REPOSITORY_ROOT / ".build" / "public-api"
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
SYNTHETIC_PACKAGE_TEST_MODULE_PATTERN = re.compile(
    r"error: Failed to emit symbol graph for '(swift[-_]codexPackageTests)'"
)
SWIFT_VERSION_PATTERN = re.compile(r"Apple Swift version (\d+\.\d+)")


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def swift_minor_version() -> str:
    result = subprocess.run(
        ["swift", "--version"],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        check=True,
        text=True,
    )
    match = SWIFT_VERSION_PATTERN.search(result.stdout + result.stderr)
    if match is None:
        raise RuntimeError("unable to determine the Apple Swift minor version")
    return match.group(1)


def selected_fragments(fragments: object) -> list[dict[str, object]]:
    if not isinstance(fragments, list):
        return []
    return [
        {key: fragment[key] for key in ("kind", "spelling") if key in fragment}
        for fragment in fragments
        if isinstance(fragment, dict)
    ]


def selected_symbol(symbol: dict[str, object]) -> dict[str, object]:
    kind = symbol.get("kind", {})
    selected: dict[str, object] = {
        "kind": kind.get("identifier") if isinstance(kind, dict) else None,
        "pathComponents": symbol.get("pathComponents", []),
        "declarationFragments": selected_fragments(
            symbol.get("declarationFragments")
        ),
    }
    swift_extension = symbol.get("swiftExtension")
    if isinstance(swift_extension, dict):
        selected["swiftExtension"] = {
            key: swift_extension[key]
            for key in ("extendedModule", "typeKind")
            if key in swift_extension
        }
    if "availability" in symbol:
        selected["availability"] = symbol["availability"]
    return selected


def symbol_identity(symbol: dict[str, object]) -> str:
    return hashlib.sha256(canonical_json(selected_symbol(symbol))).hexdigest()


def selected_relationship(
    relationship: dict[str, object], identities: dict[str, str]
) -> dict[str, object]:
    source = str(relationship.get("source", ""))
    target = str(relationship.get("target", ""))
    selected: dict[str, object] = {
        "kind": relationship.get("kind"),
        "source": identities.get(source, source),
        "target": identities.get(
            target, str(relationship.get("targetFallback", target))
        ),
    }
    if "swiftConstraints" in relationship:
        selected["swiftConstraints"] = relationship["swiftConstraints"]
    return selected


def graph_paths(
    module: str, symbol_graph_directory: pathlib.Path
) -> list[pathlib.Path]:
    direct = symbol_graph_directory / f"{module}.symbols.json"
    extensions = sorted(symbol_graph_directory.glob(f"{module}@*.symbols.json"))
    return [direct, *extensions]


def module_baseline(
    module: str, symbol_graph_directory: pathlib.Path
) -> dict[str, object]:
    raw_symbols: list[dict[str, object]] = []
    raw_relationships: list[dict[str, object]] = []
    for path in graph_paths(module, symbol_graph_directory):
        if not path.is_file():
            raise RuntimeError(f"missing symbol graph: {path.relative_to(REPOSITORY_ROOT)}")
        graph = json.loads(path.read_text(encoding="utf-8"))
        if graph.get("module", {}).get("name") != module:
            raise RuntimeError(f"unexpected module name in {path.name}")
        raw_symbols.extend(graph.get("symbols", []))
        raw_relationships.extend(graph.get("relationships", []))

    identities = {
        str(symbol.get("identifier", {}).get("precise", "")): symbol_identity(symbol)
        for symbol in raw_symbols
        if isinstance(symbol.get("identifier"), dict)
    }
    symbols = [selected_symbol(symbol) for symbol in raw_symbols]
    relationships = [
        selected_relationship(relationship, identities)
        for relationship in raw_relationships
    ]

    symbols.sort(key=lambda value: canonical_json(value))
    relationships.sort(key=lambda value: canonical_json(value))
    payload = {"symbols": symbols, "relationships": relationships}
    return {
        "name": module,
        "symbol_count": len(symbols),
        "relationship_count": len(relationships),
        "api_sha256": hashlib.sha256(canonical_json(payload)).hexdigest(),
    }


def clean_symbol_graph_outputs() -> None:
    for directory in API_SCRATCH_DIRECTORY.glob("*/symbolgraph"):
        shutil.rmtree(directory, ignore_errors=True)


def resolved_symbol_graph_directory() -> pathlib.Path:
    candidates = sorted(API_SCRATCH_DIRECTORY.glob("*/symbolgraph"))
    complete_candidates = [
        directory
        for directory in candidates
        if all(
            (directory / f"{module}.symbols.json").is_file()
            for module in PUBLIC_MODULES
        )
    ]
    if len(complete_candidates) != 1:
        relative_candidates = [
            str(directory.relative_to(REPOSITORY_ROOT)) for directory in candidates
        ]
        raise RuntimeError(
            "expected exactly one complete release symbol-graph directory; "
            f"found {relative_candidates}"
        )
    return complete_candidates[0]


def build_baseline() -> dict[str, object]:
    subprocess.run(
        [
            "swift",
            "package",
            "--scratch-path",
            str(API_SCRATCH_DIRECTORY),
            "clean",
        ],
        cwd=REPOSITORY_ROOT,
        check=True,
    )
    clean_symbol_graph_outputs()
    result = subprocess.run(
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
        capture_output=True,
        text=True,
    )
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        failed_modules = re.findall(
            r"error: Failed to emit symbol graph for '([^']+)'",
            result.stdout + result.stderr,
        )
        ignored_synthetic_failure = (
            len(failed_modules) == 1
            and SYNTHETIC_PACKAGE_TEST_MODULE_PATTERN.search(
                result.stdout + result.stderr
            )
            is not None
        )
        if not ignored_synthetic_failure:
            raise subprocess.CalledProcessError(result.returncode, result.args)
        print(
            "Ignoring SwiftPM's synthetic package-test symbol graph failure; "
            "all release module graphs remain mandatory.",
            file=sys.stderr,
        )
    symbol_graph_directory = resolved_symbol_graph_directory()
    return {
        "swift_minor": swift_minor_version(),
        "generator": {
            "command": "swift package dump-symbol-graph",
            "minimum_access_level": "public",
            "normalization": "semantic-declarations-and-relationships-v1",
            "skip_inherited_docs": True,
            "skip_synthesized_members": True,
        },
        "modules": [
            module_baseline(module, symbol_graph_directory)
            for module in PUBLIC_MODULES
        ],
    }


def merged_baseline(
    snapshot: dict[str, object], existing: dict[str, object] | None
) -> dict[str, object]:
    swift_minor = str(snapshot["swift_minor"])
    existing_modules: dict[str, dict[str, object]] = {}
    if existing is not None and existing.get("schema_version") == 3:
        existing_modules = {
            str(module["name"]): module
            for module in existing.get("modules", [])
            if isinstance(module, dict) and "name" in module
        }

    modules: list[dict[str, object]] = []
    for module in snapshot["modules"]:
        if not isinstance(module, dict):
            raise RuntimeError("invalid generated module baseline")
        name = str(module["name"])
        prior_hashes = existing_modules.get(name, {}).get(
            "api_sha256_by_swift_minor", {}
        )
        hashes = dict(prior_hashes) if isinstance(prior_hashes, dict) else {}
        hashes[swift_minor] = module["api_sha256"]
        modules.append(
            {
                "name": name,
                "symbol_count": module["symbol_count"],
                "relationship_count": module["relationship_count"],
                "api_sha256_by_swift_minor": dict(sorted(hashes.items())),
            }
        )

    recorded_minors = sorted(
        {
            minor
            for module in modules
            for minor in module["api_sha256_by_swift_minor"]
        }
    )
    return {
        "schema_version": 3,
        "generator": snapshot["generator"],
        "recorded_swift_minors": recorded_minors,
        "modules": modules,
    }


def verify_snapshot(
    snapshot: dict[str, object], expected: dict[str, object]
) -> list[str]:
    problems: list[str] = []
    if expected.get("schema_version") != 3:
        problems.append("baseline schema_version must be 3")
    if expected.get("generator") != snapshot.get("generator"):
        problems.append("baseline generator configuration differs")

    swift_minor = str(snapshot["swift_minor"])
    expected_modules = {
        str(module["name"]): module
        for module in expected.get("modules", [])
        if isinstance(module, dict) and "name" in module
    }
    actual_modules = {
        str(module["name"]): module
        for module in snapshot.get("modules", [])
        if isinstance(module, dict) and "name" in module
    }
    if set(expected_modules) != set(actual_modules):
        problems.append(
            "module inventory differs: "
            f"expected={sorted(expected_modules)} actual={sorted(actual_modules)}"
        )

    for module in sorted(set(expected_modules) & set(actual_modules)):
        expected_module = expected_modules[module]
        actual_module = actual_modules[module]
        for count_key in ("symbol_count", "relationship_count"):
            if expected_module.get(count_key) != actual_module.get(count_key):
                problems.append(
                    f"{module} {count_key}: expected "
                    f"{expected_module.get(count_key)} actual "
                    f"{actual_module.get(count_key)}"
                )
        hashes = expected_module.get("api_sha256_by_swift_minor", {})
        expected_hash = hashes.get(swift_minor) if isinstance(hashes, dict) else None
        if expected_hash is None:
            problems.append(
                f"{module} has no recorded API hash for Apple Swift {swift_minor}"
            )
        elif expected_hash != actual_module.get("api_sha256"):
            problems.append(
                f"{module} API hash for Apple Swift {swift_minor}: "
                f"expected {expected_hash} actual {actual_module.get('api_sha256')}"
            )

    recorded_minors = expected.get("recorded_swift_minors")
    derived_minors = sorted(
        {
            minor
            for module in expected_modules.values()
            for minor in (
                module.get("api_sha256_by_swift_minor", {}).keys()
                if isinstance(module.get("api_sha256_by_swift_minor"), dict)
                else []
            )
        }
    )
    if recorded_minors != derived_minors:
        problems.append(
            "recorded_swift_minors does not match module hash inventories"
        )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--update",
        action="store_true",
        help="replace API/PublicAPI.json with the current public API",
    )
    arguments = parser.parse_args()

    snapshot = build_baseline()
    if arguments.update:
        existing = None
        if BASELINE_PATH.is_file():
            existing = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
        baseline = merged_baseline(snapshot, existing)
        serialized = json.dumps(baseline, indent=2, sort_keys=True) + "\n"
        BASELINE_PATH.parent.mkdir(parents=True, exist_ok=True)
        BASELINE_PATH.write_text(serialized, encoding="utf-8")
        print(
            f"Updated {BASELINE_PATH.relative_to(REPOSITORY_ROOT)} for "
            f"Apple Swift {snapshot['swift_minor']}"
        )
        return 0

    if not BASELINE_PATH.is_file():
        print("Public API baseline is missing; run with --update.", file=sys.stderr)
        return 1
    expected = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    problems = verify_snapshot(snapshot, expected)
    if problems:
        print(
            "Public API differs from API/PublicAPI.json; review the API change "
            "and run Scripts/verify-public-api.py --update if intentional.",
            file=sys.stderr,
        )
        for problem in problems:
            print(f"- {problem}", file=sys.stderr)
        return 1
    print(
        "Public API baseline verification passed for "
        f"Apple Swift {snapshot['swift_minor']}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
