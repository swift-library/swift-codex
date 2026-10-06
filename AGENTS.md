# Contributor Guide

Use this guide for repository work.

For branch, worktree, artifact or dependency maintenance, follow the ownership
and closeout rules in `CONTRIBUTING.md`.

## Package Boundaries

- Inspect `Package.swift` before changing targets, products, or dependencies.
- Keep all eleven library products buildable independently.
- `Codex` may depend on `CodexExec`: Exec owns process and JSONL behavior;
  Codex owns thread and turn conveniences.
- Keep App Server Protocol, Runtime, Client, Stdio, URLSession, NIO, Vapor, and
  Hummingbird roles separate.
- Keep `CodexMCP` independent from App Server and Exec implementations.
- Do not expose implementation-only state, channels, probes, or test fixtures
  as public API.

## Vendored Protocol

- The schema lock, file manifests, license, notice, method adoption manifest,
  API inventory, and API diff must move together.
- Do not hand-edit generated Swift output or commit build-plugin output.
- Do not add a typed or raw client method without an explicit adoption decision.

## Security and Repository Hygiene

- Never commit credentials, private keys, local paths, `.build`,
  `.doccarchive`, `.agent`, `.codex`, or `.refs.yaml`.
- Keep Actions pinned to full commit SHAs.
- Preserve subprocess stderr only as bounded, redacted diagnostics.

## Validation

Run from the repository root:

```sh
Scripts/verify-public-repository.sh
Scripts/verify-schema-snapshot.sh
swift-format lint --strict --recursive --configuration .swift-format \
  Package.swift Sources Tests Plugins
/usr/bin/swift build
/usr/bin/swift build --build-system native
/usr/bin/swift test --no-parallel
/usr/bin/swift test --build-system native --no-parallel
Scripts/verify-documentation.sh
```

Use the pinned Codex CLI version for opt-in App Server and MCP integration
tests before a release.

## Code Review Rules

### Compatibility and versioning

- Flag a change to public API or observable behavior, including a raised
  minimum platform or Swift version, without a `CHANGELOG.md` entry or a release version
  consistent with `RELEASING.md`. Safe path: record the change under the next
  version and follow that compatibility policy.

### Claims

- Flag README, DocC, or release-note statements that the code and tests do
  not support: capabilities that do not exist, existing behavior described as
  new, or platforms CI does not build. Safe path: describe what the code
  shows.

### Public documentation

- Flag a new public symbol without a documentation comment, and public prose
  that compares the package with other projects or describes internal
  process. Safe path: document the symbol, and describe only this package's
  own behavior.

### Tests

- Flag a behavior change without a test that would fail before the change.
  Safe path: add the test beside the existing suite for that behavior.
