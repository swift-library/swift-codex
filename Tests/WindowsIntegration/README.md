# Windows runtime validation

This package consumes the public Stdio, Runtime and Exec products. Its native process
fixture supplies controlled pipe and process-tree behavior; it does not execute a
model or provide authenticated Codex acceptance. All eleven SDK products have a
separate Windows build audit, including network products with upstream limitations.

From the repository root on Windows, run both debug and release configurations:

```powershell
./Tests/WindowsIntegration/BuildFixtures.ps1 -Configuration debug
swift test --package-path Tests/WindowsIntegration --no-parallel -c debug
./Tests/WindowsIntegration/BuildFixtures.ps1 -Configuration release
swift test --package-path Tests/WindowsIntegration --no-parallel -c release
```

The fixtures are built as sibling executables. They are not test-target link
dependencies, so their entry points cannot replace the test runner. The native C
environment fixture reads PATH directly through Win32 without requiring Swift
runtime DLL lookup or a command interpreter; the script builds it with Clang.
Swift Testing and XCTest runtime DLL directories must come from the installed Swift toolchain.

The tests retain native process handles before requesting exit or cancellation,
then require those exact objects to be signalled. They check short pipe messages,
blocked stdin, inherited descendant handles, independent concurrent invocations,
Unicode/empty/quoted arguments, exact environment and working directory, stdin
EOF, exit-code bits, and bounded output with explicit omitted-byte metadata.
Version-probe and inbound/outbound-buffer failures must reclaim the exact owned
process handles.
