# Releasing swift-codex

Releases are cut from a clean, reviewed default branch. The first public
release is `0.1.0`; that tag establishes the package's API compatibility
baseline.

## Versioning

- Tags use `vMAJOR.MINOR.PATCH`.
- Package consumers should use `.upToNextMinor(from: "0.1.0")` during `0.x`.
- During `0.x`, minor releases may contain deliberate source-breaking changes.
- Patch releases remain source-compatible and do not change the pinned
  upstream stable protocol contract incompatibly.
- Experimental AppServer models may change when the pinned upstream
  experimental schema changes. Such changes must still be called out in the
  changelog.

## Release Gate

From the repository root, run:

```sh
Scripts/verify-public-repository.sh
Scripts/verify-schema-snapshot.sh
Scripts/verify-dependency-manifest.py
Scripts/verify-public-api.py
Scripts/verify-documentation.sh
swift-format lint --strict --recursive --configuration .swift-format \
  Package.swift Sources Tests Plugins
swift build
swift test --no-parallel
Scripts/verify-native-build-and-test.sh
```

Run the GitHub `Real Codex Binary` workflow against the intended release ref.
It installs the Codex version matching the vendored schema tag and executes the
credential-free AppServer and MCP binary checks.

Before tagging:

1. Move the complete changelog entry from `Unreleased` to the release version
   and add the release date.
2. Confirm `Vendor/CodexAppServerProtocolSchema/upstream.lock.json` records an
   exact upstream commit, tag, file inventory, and aggregate hashes.
3. Confirm all 11 DocC catalogs build without unresolved links or warnings.
4. Generate and verify the public API inventory. Compare it with the previous
   release when one exists.
5. Confirm generated Swift output, `.build`, DocC archives, credentials, and
   machine-local paths are not tracked.
6. Resolve and build a fresh consumer without this repository's `.build` or a
   sibling checkout.
7. Confirm the worktree is clean and all required checks are green.

Create and push the release only after review:

```sh
git push origin master
git tag -s -a v0.1.0 -m "swift-codex 0.1.0"
git push origin v0.1.0
```

After publishing, check out the remote tag in an empty directory and repeat
resolve, build, test, schema, API, and documentation verification before
declaring the release complete.

Do not move or replace a published tag. Correct a bad release with a new patch
version.
