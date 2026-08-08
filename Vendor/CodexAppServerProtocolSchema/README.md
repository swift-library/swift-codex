# Codex App Server Protocol Schema

This directory vendors the upstream `codex app-server` protocol JSON Schema
snapshot used by `CodexAppServer` code generation.

## Authority

- Upstream repository: `openai/codex`
- Upstream commit:
  `be6e8eac029b183056b7e4402879f15d2c85f61b` (`rust-v0.147.0`)
- Upstream source root: `codex-rs/app-server-protocol`
- Upstream toolchain source: `codex-rs/rust-toolchain.toml`

The schema authority is the pinned upstream checkout, its committed stable and
experimental precomputed exports, and the Rust toolchain declared by that
checkout. The stable export must reproduce the checked-in upstream JSON tree
byte-for-byte. Do not substitute an installed `codex` CLI as schema authority.

## Upstream Generator Alignment

`swift-codex` aligns to upstream's schema generation outputs rather than a
separate IDL. Upstream `generate-json-schema` is the primary input for Swift
protocol-model generation. Upstream `generate-ts` may be used as a comparison
oracle for naming, union shape, and stable/experimental parity, but generated
Swift must not parse TypeScript as its source of truth.

Protobuf, `.proto`, and custom IDL translation layers are not part of this
vendored schema route.

## Contents

- `upstream.lock.json`: exact upstream provenance and artifact metadata.
- `stable.manifest.sha256` and `experimental.manifest.sha256`: stable,
  path-sorted SHA-256 inventories for every JSON file.
- `LICENSE` and `NOTICE`: Apache-2.0 terms and the applicable OpenAI notice.
- `stable/json/`: stable JSON Schema snapshot.
- `experimental/json/`: experimental JSON Schema snapshot generated with
  upstream `--experimental`.

Only JSON Schema artifacts are vendored here. Generated Swift output is derived
by the SwiftPM build-tool plugin into its plugin work directory during ordinary
`swift build` and `swift test`; it is never checked into `Sources/`.

## Refresh SOP

1. Clone or update `openai/codex`.
2. Check out the commit recorded in `upstream.lock.json`.
3. Enter the upstream `codex-rs` directory.
4. Use the Rust toolchain declared in upstream `codex-rs/rust-toolchain.toml`.
5. Generate stable fixtures:

   ```sh
   cargo run -p codex-app-server-protocol --bin write_schema_fixtures -- \
     --schema-root /tmp/codex-app-server-schema/stable
   ```

6. Verify stable output against upstream checked-in fixtures:

   ```sh
   diff -qr \
     /path/to/codex/codex-rs/app-server-protocol/schema/json \
     /tmp/codex-app-server-schema/stable/json
   ```

7. Generate experimental fixtures from the same checkout and toolchain:

   ```sh
   cargo run -p codex-app-server-protocol --bin write_schema_fixtures -- \
     --schema-root /tmp/codex-app-server-schema/experimental \
     --experimental
   ```

8. Replace `stable/json/` from the upstream checked-in stable fixtures and
   `experimental/json/` from the generated experimental fixtures.
9. Update tag, dereferenced commit, toolchain, precomputed-export hashes, and
   provenance in `upstream.lock.json`.
10. Run `Scripts/refresh-schema-metadata.py` to rewrite the path-sorted
    manifests, file counts, bundle hashes, and deterministic tree hashes.
11. Run `Scripts/verify-schema-snapshot.sh`, strict `swift-format` lint,
    `swift build`, and `swift test --no-parallel`.

Ordinary `swift build` and `swift test` must not contact the upstream checkout
or run schema generation.
