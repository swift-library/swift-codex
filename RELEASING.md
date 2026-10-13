# Releasing swift-codex

Follow the [shared release standard](https://github.com/swift-library/.github/blob/master/VERSIONING.md).
`VERSION` declares the package version, `CHANGELOG.md` records release notes,
and `.github/release.json` selects the shared validation matrix.

## Compatibility surface

All eleven library products share one version. Compatibility includes public
Swift APIs, process and transport behavior, protocol models and compiler/platform
requirements. Experimental App Server models follow the pinned experimental
schema; changes to that surface belong in the changelog.

## Requirements and validation

The package requires Swift 6.2 and macOS 14. Shared CI tests Swift 6.2 on macOS 15 and Swift 6.3
on macOS 26 and runs repository, schema, dependency, API, formatting and DocC
checks. Additional CI retains Windows product and process tests, public API
compatibility diagnosis, and the pinned real-binary integration tests.

`Scripts/check` runs the complete macOS gate. Its `--compiler-check` scope
builds and tests with the default engine and runs the isolated native gate;
`--quality-check` checks repository integrity, schema and dependency manifests,
public API baselines, strict formatting and all eleven DocC catalogs.
The native gate constrains only the built Swift Testing process and requires
both Exec stress suites to execute successfully.

Run the `Real Codex Binary` workflow against the intended release ref for
credential-free App Server and MCP integration. Verify a fresh remote consumer
and inspect its resolved dependency graph before publishing. Evidence belongs
in `.build/release-validation`.

## Public API Baselines

Run the public API verifier with its update option after an accepted API change.
The baseline records hashes for each Apple Swift minor used by the release gate.
For a hosted toolchain unavailable locally, dispatch API Breaking Changes against
the candidate branch and download the public-api-snapshot artifact. Its manual
run generates a baseline; pull request runs diagnose compatibility. Confirm the
run's source commit and toolchain, merge the freshly generated records with the
local toolchain records, and verify the committed result locally and through the
candidate's Repository quality check. Do not
retain a hash from an older API merely because its compiler is unavailable.
