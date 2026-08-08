#!/usr/bin/env python3
"""Generate or verify the deterministic SwiftPM dependency manifest."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK_PATH = REPOSITORY_ROOT / "Package.resolved"
MANIFEST_PATH = REPOSITORY_ROOT / "DEPENDENCIES.json"
DIRECT_ROLES = {
    "hummingbird": "runtime",
    "hummingbird-websocket": "runtime",
    "swift-docc-plugin": "documentation-tool",
    "swift-nio": "runtime",
    "swift-nio-ssl": "runtime",
    "swift-sdk": "runtime",
    "swift-system": "runtime",
    "vapor": "runtime",
}


def load_dependency_graph() -> dict[str, object]:
    output = subprocess.run(
        ["swift", "package", "show-dependencies", "--format", "json"],
        cwd=REPOSITORY_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    return json.loads(output)


def collect_reachable(
    node: dict[str, object],
    direct_identity: str,
    role: str,
    required_by: dict[str, set[str]],
    roles: dict[str, set[str]],
    visited: set[str],
) -> None:
    identity = str(node["identity"])
    if identity in visited:
        return
    visited.add(identity)
    required_by.setdefault(identity, set()).add(direct_identity)
    roles.setdefault(identity, set()).add(role)
    for dependency in node.get("dependencies", []):
        collect_reachable(
            dependency,
            direct_identity,
            role,
            required_by,
            roles,
            visited,
        )


def collect_checkout_paths(
    node: dict[str, object], paths: dict[str, pathlib.Path]
) -> None:
    identity = str(node["identity"])
    path = pathlib.Path(str(node["path"]))
    existing = paths.setdefault(identity, path)
    if existing != path:
        raise RuntimeError(f"dependency has inconsistent checkout paths: {identity}")
    for dependency in node.get("dependencies", []):
        collect_checkout_paths(dependency, paths)


def build_manifest() -> dict[str, object]:
    graph = load_dependency_graph()
    direct_nodes = {
        str(dependency["identity"]): dependency
        for dependency in graph.get("dependencies", [])
    }
    if set(direct_nodes) != set(DIRECT_ROLES):
        raise RuntimeError(
            f"direct dependency set differs from policy: {sorted(direct_nodes)}"
        )

    required_by: dict[str, set[str]] = {}
    roles: dict[str, set[str]] = {}
    checkout_paths: dict[str, pathlib.Path] = {}
    for identity, role in DIRECT_ROLES.items():
        collect_checkout_paths(direct_nodes[identity], checkout_paths)
        collect_reachable(
            direct_nodes[identity],
            identity,
            role,
            required_by,
            roles,
            set(),
        )

    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    dependencies: list[dict[str, object]] = []
    for pin in sorted(lock.get("pins", []), key=lambda value: value["identity"]):
        identity = pin["identity"]
        state = pin["state"]
        revision = state.get("revision")
        version = state.get("version")
        if not version or not revision or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise RuntimeError(f"dependency is not versioned and commit-pinned: {identity}")
        if identity not in required_by:
            raise RuntimeError(f"resolved dependency is absent from dependency graph: {identity}")
        checkout_path = checkout_paths[identity]
        license_files = sorted(
            child.name
            for child in checkout_path.iterdir()
            if child.is_file()
            and child.name.lower().startswith(("license", "copying"))
        )
        if not license_files:
            raise RuntimeError(f"dependency checkout has no root license file: {identity}")
        dependencies.append(
            {
                "identity": identity,
                "location": pin["location"],
                "version": version,
                "revision": revision,
                "license_files": license_files,
                "direct": identity in DIRECT_ROLES,
                "roles": sorted(roles[identity]),
                "required_by": sorted(required_by[identity]),
            }
        )

    if set(required_by) != {dependency["identity"] for dependency in dependencies}:
        raise RuntimeError("dependency graph and Package.resolved do not contain the same pins")
    return {
        "schema_version": 1,
        "source": "Package.resolved",
        "distribution_note": (
            "SwiftPM resolves these source dependencies for consumers; they are not "
            "vendored in this repository."
        ),
        "dependencies": dependencies,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true")
    arguments = parser.parse_args()
    serialized = json.dumps(build_manifest(), indent=2, sort_keys=True) + "\n"
    if arguments.update:
        MANIFEST_PATH.write_text(serialized, encoding="utf-8")
        print(f"Updated {MANIFEST_PATH.name}")
        return 0
    if not MANIFEST_PATH.is_file() or MANIFEST_PATH.read_text(encoding="utf-8") != serialized:
        print(
            "Dependency manifest differs from Package.resolved; review the change and "
            "run Scripts/verify-dependency-manifest.py --update if intentional.",
            file=sys.stderr,
        )
        return 1
    print("Dependency manifest verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
