# Release

All eleven library products share the version declared in `VERSION`.
`CHANGELOG.md` records release notes, and `.github/release.json` declares the
repository, version source, changelog, minimum Swift version and release
platforms.

Compatibility includes public Swift APIs, process and transport behavior,
protocol models, and compiler/platform requirements. Experimental App Server
models follow the pinned experimental schema; changes to that surface belong
in the changelog.

## Validation

The package requires Swift 6.3 or later and macOS 15 or later.
`.github/swift-package.json` declares one compiler entry: Xcode 26.6 on
`macos-26`, with strict formatting, tests, a release build, all eleven DocC catalogs,
and the schema, dependency-manifest and native stress checks in `scripts/`.
The native stress check requires both Exec suites to pass with the strict
cooperative thread pool enabled in the test process.

Run the [local validation commands](../../CONTRIBUTING.md#local-validation)
before submitting changes. The required checks are `policy / policy` and
`result`, which also requires the Windows product builds and the real-binary
integration tests.

Run the `Real Codex Binary` workflow against the intended release ref for
credential-free App Server and MCP integration.

## Publication

The `Release` workflow validates the tagged commit through the shared package
workflow, then calls the shared release workflow to verify the signed annotated
tag, version and changelog and publish the release notes. Follow the
[shared release standard](https://github.com/swift-library/.github/blob/master/VERSIONING.md)
for versioning and tag creation.
