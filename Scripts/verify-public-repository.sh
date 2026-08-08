#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

fail() {
  echo "Public repository verification failed: $1" >&2
  exit 1
}

repository_files() {
  git ls-files --cached --others --exclude-standard -- "$@"
}

repository_files_null() {
  git ls-files -z --cached --others --exclude-standard -- "$@"
}

repository_content_files_null() {
  git ls-files -z --cached --others --exclude-standard -- \
    . \
    ':(exclude)Scripts/verify-public-repository.sh' \
    "$@"
}

repository_files . | rg '(^|/)(\.DS_Store|\.build|DerivedData|xcuserdata)(/|$)|\.doccarchive$' \
  && fail "generated build or IDE artifacts are present"

if repository_files . | rg '(^|/)(\.agent|\.codex)(/|$)|(^|/)\.refs\.yaml$'; then
  fail "local agent overlays are present in the public tree"
fi

if repository_files_null . | python3 -c '
import os
import sys

limit = 5 * 1024 * 1024
oversized = []
for raw_path in sys.stdin.buffer.read().split(b"\0"):
    if not raw_path:
        continue
    path = os.fsdecode(raw_path)
    if os.path.isfile(path) and os.path.getsize(path) > limit:
        oversized.append((os.path.getsize(path), path))
for size, path in oversized:
    print(f"{size} {path}")
raise SystemExit(0 if oversized else 1)
'; then
  fail "a repository file exceeds the 5 MiB source limit"
fi

if repository_files . | rg '^Sources/CodexAppServer[^/]*/Generated/'; then
  fail "build-derived AppServer Swift output is present"
fi

if repository_content_files_null ':(exclude)Vendor/**' | xargs -0 rg -n --no-messages \
  -e '/Users/|/home/|[A-Za-z]:\\Users\\'; then
  fail "machine-local paths are present"
fi

if repository_content_files_null | xargs -0 rg -n --no-messages \
  -e '<swift-codex-repo-url>|REPLACE_ME|YOUR_[A-Z_]*'; then
  fail "release placeholders are present"
fi

if repository_content_files_null | xargs -0 rg -n --no-messages -F 'Docs/'; then
  fail "obsolete Docs/ paths are present"
fi

if repository_content_files_null ':(exclude)Vendor/**' | xargs -0 rg -n --no-messages \
  -e 'sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
  fail "a credential-shaped value is present"
fi

if rg -n -e 'import XCTest|XCTestCase' Tests; then
  fail "XCTest remains in package tests"
fi

if ! rg -q 'https://github.com/swift-library/swift-codex\.git' README.md; then
  fail "README does not use the canonical repository URL"
fi

if ! rg -q '\.upToNextMinor\(from: "0\.1\.0"\)' README.md; then
  fail "README does not use the documented 0.x dependency policy"
fi

swift package dump-package | python3 -c '
import json
import sys

expected = sorted([
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
])
package = json.load(sys.stdin)
products = package.get("products", [])
actual = sorted(product.get("name") for product in products)
if actual != expected:
  raise SystemExit(f"unexpected public products: {actual}")
if any("library" not in product.get("type", {}) for product in products):
  raise SystemExit("every public product must be a library")
' || fail "Package.swift does not expose exactly the 11 supported libraries"

for required_file in \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  DEPENDENCIES.json \
  API/PublicAPI.json \
  Vendor/CodexAppServerProtocolSchema/LICENSE \
  Vendor/CodexAppServerProtocolSchema/NOTICE \
  Vendor/CodexAppServerProtocolSchema/method-adoption.json \
  Vendor/CodexAppServerProtocolSchema/api-inventory.json \
  Vendor/CodexAppServerProtocolSchema/api-change-report.json; do
  [[ -s "$required_file" ]] || fail "required release file is missing: $required_file"
done

if repository_content_files_null ':(exclude)Vendor/**' | xargs -0 rg -n --no-messages \
  -i -e '\b(apple-style|donor|distillation)\b' \
  -e 'CodexAppServerAsyncHTTPClient' \
  -e 'current-stage'; then
  fail "internal process language or a removed product name is present"
fi

while IFS= read -r use_line; do
  [[ "$use_line" =~ uses:[[:space:]]+[^[:space:]@]+@[0-9a-fA-F]{40}([[:space:]]|$) ]] \
    || fail "GitHub Actions must be pinned to a full commit SHA: $use_line"
done < <(rg --no-filename '^\s*-?\s*uses:' .github/workflows || true)

if [[ "$(find Sources -type d -name '*.docc' | wc -l | tr -d ' ')" != "11" ]]; then
  fail "every public library target must have one DocC catalog"
fi

echo "Public repository verification passed."
