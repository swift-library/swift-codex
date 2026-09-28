# Windows runtime validation

This package consumes the public Stdio and Exec products. Its native process
fixture supplies controlled pipe and process-tree behavior; it does not execute a
model or provide authenticated Codex acceptance. All eleven SDK products have a
separate Windows build audit, including network products with upstream limitations.

From the repository root on Windows, run both debug and release configurations:

```powershell
swift build --package-path Tests/WindowsIntegration --product CodexProcessFixture -c debug
swift test --package-path Tests/WindowsIntegration --no-parallel -c debug
swift build --package-path Tests/WindowsIntegration --product CodexProcessFixture -c release
swift test --package-path Tests/WindowsIntegration --no-parallel -c release
```

The fixture is built as a sibling executable. It is not a test-target link
dependency, so its entry point cannot replace the test runner. Swift Testing and
XCTest runtime DLL directories must come from the installed Swift toolchain.

The tests retain native process handles before requesting exit or cancellation,
then require those exact objects to be signalled. They check short pipe messages,
blocked stdin, inherited descendant handles, independent concurrent invocations,
Unicode/empty/quoted arguments, exact environment and working directory, stdin
EOF, exit-code bits, and bounded output with explicit omitted-byte metadata.
