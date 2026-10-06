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

The isolated native gate uses the selected Xcode toolchain for its build and
test runtime. It applies the single-worker cooperative-pool constraint only to
the built Swift Testing process, and requires both Exec stress suites to report
executed, passing cases. SwiftPM package planning itself runs without that
constraint.

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
7. Open a pull request for the release preparation branch. Address or answer
   review findings and confirm all required checks pass before squash-merging
   the reviewed head. Follow the organization's
   [PR workflow](https://github.com/swift-library/.github/blob/master/MAINTENANCE.md).
8. Fetch the merged default branch and verify the clean merged candidate and
   its required checks before tagging. Use that accepted commit for the tag.

Set `release_tag` to the intended immutable `vMAJOR.MINOR.PATCH` tag and
`accepted_commit` to the validated merged commit. Create a signed annotated
tag only after the above acceptance:

```sh
git tag -s -a "$release_tag" "$accepted_commit" -m "swift-codex $release_tag"
git push origin "$release_tag"
```

After publishing, check out the remote tag in an empty directory and repeat
resolve, build, test, schema, API, and documentation verification before
declaring the release complete.

Do not move or replace a published tag. Correct a bad release with a new patch
version.
