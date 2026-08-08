#!/bin/bash

set -euo pipefail

package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$package_root/.docc-build/verification-$$"
output_root="$workspace_root/archives"
symbol_root="$workspace_root/symbols"

cleanup() {
  if [[ "$workspace_root" == "$package_root"/.docc-build/verification-* ]] &&
    [[ -d "$workspace_root" ]]; then
    find "$workspace_root" -depth -delete
  fi
}

trap cleanup EXIT
mkdir -p "$output_root" "$symbol_root"

targets=(
  Codex
  CodexExec
  CodexMCP
  CodexAppServerRuntime
  CodexAppServerProtocol
  CodexAppServerClient
  CodexAppServerStdio
  CodexAppServerURLSession
  CodexAppServerNIO
  CodexAppServerVapor
  CodexAppServerHummingbird
)

swift package dump-package | python3 -c '
import json
import sys

package = json.load(sys.stdin)
expected = set(sys.argv[1:])
actual = {
    product["name"]
    for product in package["products"]
    if product["type"] == {"library": ["automatic"]}
}
if actual != expected:
    print(f"DocC target mismatch: expected={sorted(expected)}, actual={sorted(actual)}", file=sys.stderr)
    raise SystemExit(1)
' "${targets[@]}"

"$package_root/Scripts/verify-public-api.py"
symbol_graph_root="$package_root/.build/public-api/out/symbolgraph"

for target in "${targets[@]}"; do
  archive="$output_root/$target.doccarchive"
  target_symbol_root="$symbol_root/$target"
  module_name="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
  module_page="$archive/data/documentation/$module_name.json"
  catalog="$package_root/Sources/$target/Documentation.docc"

  mkdir -p "$target_symbol_root"
  cp "$symbol_graph_root/$target.symbols.json" "$target_symbol_root/"
  for extension_graph in "$symbol_graph_root/$target"@*.symbols.json; do
    if [[ -f "$extension_graph" ]]; then
      cp "$extension_graph" "$target_symbol_root/"
    fi
  done

  xcrun docc convert \
    "$catalog" \
    --additional-symbol-graph-dir "$target_symbol_root" \
    --output-path "$archive" \
    --warnings-as-errors \
    --fallback-display-name "$target" \
    --fallback-bundle-identifier "com.swift-library.swift-codex.$module_name" \
    --fallback-default-module-kind Library

  test -f "$archive/metadata.json"
  test -f "$module_page"
  rg -q '"primaryContentSections"' "$module_page"
done

printf 'Verified DocC archives for %s public library targets.\n' "${#targets[@]}"
