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
unset LIBDISPATCH_COOPERATIVE_POOL_STRICT

# Keep the build, test helper and runtime frameworks on the selected Xcode toolchain.
swift_executable="$(xcrun --find swift)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
test_helper="$(dirname "$swift_executable")/../libexec/swift/pm/swiftpm-testing-helper"
[[ -x "$test_helper" ]] || { echo "Swift Testing helper is unavailable" >&2; exit 1; }

"$swift_executable" build --build-system native --scratch-path "$native_scratch"
"$swift_executable" test --build-system native --scratch-path "$native_scratch" --no-parallel
binary_directory="$("$swift_executable" build --build-system native --scratch-path "$native_scratch" --show-bin-path)"
test_bundle="$binary_directory/swift-codexPackageTests.xctest/Contents/MacOS/swift-codexPackageTests"
[[ -f "$test_bundle" ]] || { echo "Built Swift Testing bundle is unavailable" >&2; exit 1; }
report="$native_scratch/cooperative-pool-tests.xml"

# Constrain only the actual test process, not SwiftPM's package/build planning.
# These real-pipe protocol fixtures do not contact a model.
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
  DYLD_FRAMEWORK_PATH="$platform/Developer/Library/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
  DYLD_LIBRARY_PATH="$platform/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$test_helper" --test-bundle-path "$test_bundle" --testing-library swift-testing \
    --no-parallel --filter 'CodexExecOutputCaptureTests|CodexExecAcceptanceCoverageTests' \
    --xunit-output "$report"

# Missing or empty discovery is not a successful stress run.
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
cases = root.findall(".//testcase")
expected = {"CodexExecOutputCaptureTests", "CodexExecAcceptanceCoverageTests"}
actual = {case.get("classname", "").rsplit(".", 1)[-1] for case in cases}
if not cases or actual != expected or any(root.findall(".//" + tag) for tag in ("failure", "error", "skipped")):
    raise SystemExit("Cooperative-pool tests did not execute both suites successfully")
print(f"Cooperative-pool test process: {len(cases)} cases passed in both required suites")
PY
