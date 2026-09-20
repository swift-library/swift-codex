#!/usr/bin/env python3
"""Import pinned upstream precomputed exports, verifying stable Git blob identities."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "Vendor" / "CodexAppServerProtocolSchema"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--upstream-tree", type=Path, required=True)
    parser.add_argument("--stable-export", type=Path, required=True)
    parser.add_argument("--experimental-export", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"rust-v\d+\.\d+\.\d+", args.tag):
        raise SystemExit("invalid upstream tag")
    if not re.fullmatch(r"[a-f0-9]{40}", args.commit):
        raise SystemExit("invalid upstream commit")
    tree = json.loads(args.upstream_tree.read_text())
    if tree.get("sha") != args.commit or tree.get("truncated"):
        raise SystemExit("upstream tree must be complete and match the pinned commit")
    blobs = {entry["path"]: entry["sha"] for entry in tree["tree"] if entry["type"] == "blob"}
    source = "codex-rs/app-server-protocol/schema/"
    exports = {}
    for surface in ("stable", "experimental"):
        path = getattr(args, surface + "_export")
        compressed = path.read_bytes()
        identity = hashlib.sha1(b"blob " + str(len(compressed)).encode() + b"\0" + compressed).hexdigest()
        export_name = f"precomputed/app-server-exports-{surface}.json.zst"
        if blobs.get(source + export_name) != identity:
            raise SystemExit(f"{surface}: precomputed export does not match the pinned Git blob")
        export = json.loads(subprocess.check_output(["zstd", "-dc", str(path)]))["json_schema"]
        for name, text in export.items():
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts or relative.suffix != ".json":
                raise SystemExit(f"invalid schema path: {name}")
            if surface == "stable":
                data = text.encode()
                identity = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
                if blobs.get(source + "json/" + name) != identity:
                    raise SystemExit(f"stable: checked-in upstream schema differs: {name}")
        exports[surface] = export
    expected_stable = {
        path.removeprefix(source + "json/")
        for path in blobs if path.startswith(source + "json/") and path.endswith(".json")
    }
    if set(exports["stable"]) != expected_stable:
        raise SystemExit("stable precomputed export and checked-in schema file inventories differ")

    lock_path = SCHEMA_ROOT / "upstream.lock.json"
    lock = json.loads(lock_path.read_text())
    lock["upstream"].update(tag=args.tag, commit=args.commit)
    for surface, export in exports.items():
        output = SCHEMA_ROOT / surface / "json"
        for path in output.rglob("*.json"):
            if path.relative_to(output).as_posix() not in export:
                path.unlink()
        for name, contents in export.items():
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        artifact = lock["artifacts"][surface]
        artifact["precomputedExportSha256"] = hashlib.sha256(
            getattr(args, surface + "_export").read_bytes()).hexdigest()
        artifact["provenance"] = (
            f"Extracted from the {surface} precomputed protocol export committed at {args.tag}; "
            "the compressed export's Git blob identity was verified against the pinned source tree."
            + (" Every stable JSON file was also verified against its checked-in upstream Git blob."
               if surface == "stable" else ""))
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    print(f"Imported verified schema exports from {args.tag} ({args.commit}).")


if __name__ == "__main__":
    main()
