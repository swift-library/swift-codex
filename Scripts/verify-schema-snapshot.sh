#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_root="$repository_root/Vendor/CodexAppServerProtocolSchema"
lock_file="$schema_root/upstream.lock.json"

"$repository_root/Scripts/refresh-method-adoption.py" --check

python3 - "$schema_root" "$lock_file" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

schema_root = pathlib.Path(sys.argv[1])
lock_file = pathlib.Path(sys.argv[2])

with lock_file.open(encoding="utf-8") as handle:
    lock = json.load(handle)

if lock.get("schema") != "swift-codex.codex-app-server-protocol-schema.lock.v2":
    raise SystemExit("unsupported or missing schema lock contract")

upstream = lock.get("upstream", {})
commit = upstream.get("commit", "")
tag = upstream.get("tag", "")
if upstream.get("repository") != "openai/codex":
    raise SystemExit("unexpected upstream repository")
if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("upstream commit must be a full lowercase SHA-1")
if re.fullmatch(r"rust-v[0-9]+\.[0-9]+\.[0-9]+", tag) is None:
    raise SystemExit("upstream tag must use rust-vMAJOR.MINOR.PATCH")

required_bundles = {
    "codex_app_server_protocol.schemas.json",
    "codex_app_server_protocol.v2.schemas.json",
}

for surface in ("stable", "experimental"):
    artifact = lock.get("artifacts", {}).get(surface, {})
    relative_path = artifact.get("path")
    if not isinstance(relative_path, str):
        raise SystemExit(f"{surface}: missing artifact path")

    artifact_root = schema_root / relative_path
    files = sorted(artifact_root.rglob("*.json"))
    expected_count = artifact.get("fileCount")
    if len(files) != expected_count:
        raise SystemExit(
            f"{surface}: expected {expected_count} JSON files, found {len(files)}"
        )

    manifest_name = artifact.get("fileManifest")
    if not isinstance(manifest_name, str) or pathlib.PurePath(manifest_name).name != manifest_name:
        raise SystemExit(f"{surface}: invalid file manifest path")
    manifest_path = schema_root / manifest_name
    expected_manifest = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
        f"{path.relative_to(artifact_root).as_posix()}\n"
        for path in files
    ).encode()
    actual_manifest = manifest_path.read_bytes()
    if actual_manifest != expected_manifest:
        raise SystemExit(f"{surface}: file manifest does not match the JSON tree")
    manifest_digest = hashlib.sha256(actual_manifest).hexdigest()
    if artifact.get("fileManifestSha256") != manifest_digest:
        raise SystemExit(f"{surface}: file manifest SHA-256 mismatch")
    if artifact.get("treeSha256") != manifest_digest:
        raise SystemExit(f"{surface}: deterministic tree SHA-256 mismatch")

    hashes = artifact.get("bundleSha256", {})
    if set(hashes) != required_bundles:
        raise SystemExit(f"{surface}: aggregate schema hash inventory is incomplete")

    for filename in sorted(required_bundles):
        path = artifact_root / filename
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != hashes[filename]:
            raise SystemExit(
                f"{surface}: SHA-256 mismatch for {filename}: {digest}"
            )

licensing = lock.get("licensing", {})
if licensing != {
    "spdx": "Apache-2.0",
    "license": "LICENSE",
    "notice": "NOTICE",
}:
    raise SystemExit("schema licensing metadata is incomplete")
for filename in ("LICENSE", "NOTICE"):
    path = schema_root / filename
    if not path.is_file() or not path.read_bytes():
        raise SystemExit(f"missing vendored schema {filename}")

constraints = lock.get("constraints", {})
expected_constraints = {
    "ordinarySwiftBuildGeneratesSwiftBindings": True,
    "ordinarySwiftTestGeneratesSwiftBindings": True,
    "ordinarySwiftBuildRegeneratesVendoredSchema": False,
    "ordinarySwiftTestRegeneratesVendoredSchema": False,
    "requiresUpstreamCheckoutDuringBuildOrTest": False,
    "npmCodexCliIsNotSchemaAuthority": True,
}
if constraints != expected_constraints:
    raise SystemExit("schema lock constraints do not match the release contract")

print(
    "Schema snapshot verified: "
    f"{tag} ({commit}), "
    f"stable={lock['artifacts']['stable']['fileCount']}, "
    f"experimental={lock['artifacts']['experimental']['fileCount']}"
)
PY
