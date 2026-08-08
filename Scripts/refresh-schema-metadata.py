#!/usr/bin/env python3

"""Refresh deterministic manifests and dynamic fields in the schema lock."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = REPOSITORY_ROOT / "Vendor" / "CodexAppServerProtocolSchema"
LOCK_PATH = SCHEMA_ROOT / "upstream.lock.json"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def refresh_surface(lock: dict[str, object], surface: str) -> None:
    artifacts = lock["artifacts"]
    assert isinstance(artifacts, dict)
    artifact = artifacts[surface]
    assert isinstance(artifact, dict)

    relative_root = artifact["path"]
    assert isinstance(relative_root, str)
    artifact_root = SCHEMA_ROOT / relative_root
    files = sorted(artifact_root.rglob("*.json"))

    manifest = "".join(
        f"{sha256(path.read_bytes())}  {path.relative_to(artifact_root).as_posix()}\n"
        for path in files
    ).encode()
    manifest_path = SCHEMA_ROOT / f"{surface}.manifest.sha256"
    manifest_path.write_bytes(manifest)

    artifact["fileCount"] = len(files)
    artifact["fileManifest"] = manifest_path.name
    artifact["fileManifestSha256"] = sha256(manifest)
    artifact["treeSha256"] = sha256(manifest)
    artifact["bundleSha256"] = {
        name: sha256((artifact_root / name).read_bytes())
        for name in (
            "codex_app_server_protocol.schemas.json",
            "codex_app_server_protocol.v2.schemas.json",
        )
    }


def main() -> None:
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    for surface in ("stable", "experimental"):
        refresh_surface(lock, surface)
    LOCK_PATH.write_text(
        json.dumps(lock, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    subprocess.run(
        [sys.executable, str(REPOSITORY_ROOT / "Scripts" / "refresh-method-adoption.py")],
        check=True,
    )


if __name__ == "__main__":
    main()
