#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="${TMPDIR:-/tmp}"
native_scratch="$(mktemp -d "$temporary_root/swift-codex-native.XXXXXX")"

cleanup() {
  if [[ "$native_scratch" == "$temporary_root"/swift-codex-native.* ]] &&
    [[ -d "$native_scratch" ]]; then
    find "$native_scratch" -depth -delete
  fi
}

trap cleanup EXIT
cd "$repository_root"

swift build --build-system native --scratch-path "$native_scratch"
swift test --build-system native --scratch-path "$native_scratch" --no-parallel
