#!/usr/bin/env python3

"""Validate method adoption and refresh deterministic API inventory reports."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = REPOSITORY_ROOT / "Vendor" / "CodexAppServerProtocolSchema"
MANIFEST_PATH = SCHEMA_ROOT / "method-adoption.json"
LOCK_PATH = SCHEMA_ROOT / "upstream.lock.json"
INVENTORY_PATH = SCHEMA_ROOT / "api-inventory.json"
CHANGE_REPORT_PATH = SCHEMA_ROOT / "api-change-report.json"
DOCUMENTATION_PATH = (
    REPOSITORY_ROOT / "Documentation" / "Reference" / "CodexAppServerMethodAdoption.md"
)
MANIFEST_SCHEMA = "swift-codex.codex-app-server-method-adoption.v1"
INVENTORY_SCHEMA = "swift-codex.codex-app-server-api-inventory.v1"
CHANGE_REPORT_SCHEMA = "swift-codex.codex-app-server-api-change-report.v1"


def load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return value


def schema_methods(surface: str) -> set[str]:
    request_path = SCHEMA_ROOT / surface / "json" / "ClientRequest.json"
    request = load_json(request_path)
    branches = request.get("oneOf")
    if not isinstance(branches, list):
        raise SystemExit(f"{request_path}: missing oneOf")
    methods: set[str] = set()
    for branch in branches:
        try:
            method = branch["properties"]["method"]["enum"][0]
        except (KeyError, IndexError, TypeError) as error:
            raise SystemExit(f"{request_path}: malformed method branch: {error}") from error
        if not isinstance(method, str):
            raise SystemExit(f"{request_path}: method is not a string")
        methods.add(method)
    return methods


def sorted_unique_strings(value: object, path: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SystemExit(f"{path}: expected a string array")
    if value != sorted(value) or len(value) != len(set(value)):
        raise SystemExit(f"{path}: values must be sorted and unique")
    return value


def validate_manifest() -> tuple[dict[str, object], list[dict[str, str]]]:
    manifest = load_json(MANIFEST_PATH)
    lock = load_json(LOCK_PATH)
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise SystemExit(f"{MANIFEST_PATH}: unsupported schema")
    upstream = lock.get("upstream")
    if not isinstance(upstream, dict) or manifest.get("upstreamTag") != upstream.get("tag"):
        raise SystemExit("method adoption tag does not match the schema lock")

    adopted = manifest.get("adopted")
    if not isinstance(adopted, dict):
        raise SystemExit(f"{MANIFEST_PATH}: missing adopted object")
    stable = sorted_unique_strings(adopted.get("stable"), "adopted.stable")
    experimental = sorted_unique_strings(
        adopted.get("experimental"), "adopted.experimental"
    )
    excluded = manifest.get("excluded")
    if not isinstance(excluded, list):
        raise SystemExit(f"{MANIFEST_PATH}: missing excluded array")
    if not all(
        isinstance(item, dict)
        and isinstance(item.get("method"), str)
        and isinstance(item.get("reason"), str)
        and item["reason"].strip()
        for item in excluded
    ):
        raise SystemExit("every excluded method requires a non-empty reason")
    excluded = [{"method": item["method"], "reason": item["reason"]} for item in excluded]
    if [item["method"] for item in excluded] != sorted(item["method"] for item in excluded):
        raise SystemExit("excluded methods must be sorted")

    stable_schema = schema_methods("stable")
    experimental_schema = schema_methods("experimental")
    stable_set = set(stable)
    experimental_set = set(experimental)
    excluded_set = {item["method"] for item in excluded}
    if stable_set & experimental_set or (stable_set | experimental_set) & excluded_set:
        raise SystemExit("method adoption classifications overlap")
    if not stable_set <= stable_schema:
        raise SystemExit("stable adoption contains a method absent from the stable schema")
    if not experimental_set <= (experimental_schema - stable_schema):
        raise SystemExit("experimental adoption contains a non-experimental-only method")
    schema_union = stable_schema | experimental_schema
    classified = stable_set | experimental_set | (excluded_set & schema_union)
    if classified != schema_union:
        missing = sorted(schema_union - classified)
        unknown = sorted(classified - schema_union)
        raise SystemExit(f"method adoption coverage mismatch: missing={missing}, unknown={unknown}")

    entries = [
        {"surface": "stable", "method": method} for method in stable
    ] + [
        {"surface": "experimental", "method": method} for method in experimental
    ]
    return manifest, entries


def inventory(manifest: dict[str, object], entries: list[dict[str, str]]) -> dict[str, object]:
    excluded = manifest["excluded"]
    payload = {"adopted": entries, "excluded": excluded}
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {
        "schema": INVENTORY_SCHEMA,
        "upstreamTag": manifest["upstreamTag"],
        "inventorySha256": digest,
        "adopted": entries,
        "excluded": excluded,
    }


def entry_keys(value: dict[str, object]) -> set[tuple[str, str]]:
    adopted = value.get("adopted", [])
    if not isinstance(adopted, list):
        raise SystemExit("API inventory adopted field must be an array")
    return {(entry["surface"], entry["method"]) for entry in adopted}


def make_change_report(
    previous: dict[str, object] | None, current: dict[str, object]
) -> dict[str, object]:
    previous_entries = entry_keys(previous) if previous else set()
    current_entries = entry_keys(current)
    return {
        "schema": CHANGE_REPORT_SCHEMA,
        "from": previous,
        "to": current,
        "added": [
            {"surface": surface, "method": method}
            for surface, method in sorted(current_entries - previous_entries)
        ],
        "removed": [
            {"surface": surface, "method": method}
            for surface, method in sorted(previous_entries - current_entries)
        ],
    }


def documentation(current: dict[str, object], report: dict[str, object]) -> str:
    stable = [entry["method"] for entry in current["adopted"] if entry["surface"] == "stable"]
    experimental = [
        entry["method"]
        for entry in current["adopted"]
        if entry["surface"] == "experimental"
    ]
    excluded = current["excluded"]
    added = report["added"]
    removed = report["removed"]
    lines = [
        "# Codex App Server Method Adoption",
        "",
        "This page is generated from",
        "`Vendor/CodexAppServerProtocolSchema/method-adoption.json`. The manifest",
        "is the source of truth for typed wrappers, the raw-method deny policy,",
        "and this inventory.",
        "",
        f"Pinned schema: `{current['upstreamTag']}`. Inventory SHA-256:",
        f"`{current['inventorySha256']}`.",
        "",
        f"## Stable ({len(stable)})",
        "",
        *[f"- `{method}`" for method in stable],
        "",
        f"## Experimental-only ({len(experimental)})",
        "",
        *[f"- `{method}`" for method in experimental],
        "",
        f"## Excluded ({len(excluded)})",
        "",
        *[f"- `{item['method']}` — {item['reason']}" for item in excluded],
        "",
        "## Last Schema Refresh API Diff",
        "",
        f"Added: {len(added)}. Removed: {len(removed)}.",
        "",
        "### Added",
        "",
        *([f"- `{item['surface']}` `{item['method']}`" for item in added] or ["None."]),
        "",
        "### Removed",
        "",
        *(
            [f"- `{item['surface']}` `{item['method']}`" for item in removed]
            or ["None."]
        ),
        "",
    ]
    return "\n".join(lines)


def pretty_json(value: dict[str, object]) -> str:
    return json.dumps(value, indent=2, sort_keys=False) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    manifest, entries = validate_manifest()
    current = inventory(manifest, entries)
    existing = load_json(INVENTORY_PATH) if INVENTORY_PATH.exists() else None
    if CHANGE_REPORT_PATH.exists() and existing == current:
        report = load_json(CHANGE_REPORT_PATH)
    else:
        report = make_change_report(existing, current)
    if report.get("schema") != CHANGE_REPORT_SCHEMA or report.get("to") != current:
        raise SystemExit("API change report does not target the current inventory")
    expected_report = make_change_report(report.get("from"), current)
    if report != expected_report:
        raise SystemExit("API change report diff is internally inconsistent")

    expected_files = {
        INVENTORY_PATH: pretty_json(current),
        CHANGE_REPORT_PATH: pretty_json(report),
        DOCUMENTATION_PATH: documentation(current, report),
    }
    if args.check:
        stale = [
            str(path.relative_to(REPOSITORY_ROOT))
            for path, contents in expected_files.items()
            if not path.exists() or path.read_text(encoding="utf-8") != contents
        ]
        if stale:
            raise SystemExit("stale method adoption outputs: " + ", ".join(stale))
        print("Method adoption inventory verified.")
        return

    for path, contents in expected_files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
    print(
        f"Method adoption refreshed: stable={sum(e['surface'] == 'stable' for e in entries)}, "
        f"experimental={sum(e['surface'] == 'experimental' for e in entries)}"
    )


if __name__ == "__main__":
    main()
