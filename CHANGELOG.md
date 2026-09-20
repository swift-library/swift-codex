# Changelog

All notable changes to `swift-codex` are documented in this file. The project
follows [Semantic Versioning](https://semver.org/) beginning with `0.1.0`.

## [Unreleased]

## [0.2.1] - 2026-09-19

### Fixed

- Keep blocking Exec stdin, stdout and stderr operations off Swift's cooperative
  executor so bounded capture makes progress on constrained thread pools.
- Join the stderr reader after a failed process launch instead of retaining a
  blocked pipe read.
- Exercise actual pipe capture with a constrained cooperative pool during native
  validation, and bound CI validation jobs so a stall cannot occupy a runner for
  six hours.

## [0.2.0] - 2026-09-19

### Changed

- Align generated stable and experimental App Server protocol models with
  upstream Codex 0.154.0, including explicit client method adoption.
- Validate the separate legacy MCP client against Codex 0.139.0, which exposes
  `mcp-server`; Codex 0.154.0 no longer exposes that entry point.
- Preserve native Exec configuration and approval policy. The obsolete
  `fullAuto` preset now fails before launch with this upstream version.

### Added

- Lossless App Server requests, notifications and server-request responses,
  preserving experimental and unknown fields across client boundaries.
- Bounded Exec stdout and stderr capture with explicit truncation metadata.

### Fixed

- Consume each App Server response once, including reused request identifiers
  and connection closure.
- Close Exec standard input after writing the prompt and retain native process
  termination and cancellation results.

## [0.1.2] - 2026-08-17

### Added

- Add `CodexExecRequestOptions.ignoreUserConfig`, mapping to the upstream
  `codex exec --ignore-user-config` flag while retaining `CODEX_HOME`
  authentication.

## [0.1.1] - 2026-08-09

### Fixed

- Fetch the remote annotated tag into an independent verification ref before
  checking its signature in the release workflow. This prevents the checkout
  action's peeled commit ref from replacing the signed tag object.

## [0.1.0] - 2026-08-09

### Added

- Swift-native `Codex` thread and turn interfaces backed by `CodexExec`.
- Direct non-interactive execution through `CodexExec`.
- Direct `codex mcp-server` integration through `CodexMCP`.
- Generated stable and experimental Codex AppServer protocol models pinned to
  upstream `rust-v0.147.0`.
- Typed AppServer client bindings, schema-agnostic runtime primitives, and
  stdio, URLSession, SwiftNIO, Vapor, and Hummingbird transport products.
- SwiftPM build and command plugins for deterministic AppServer protocol and
  client-binding generation.
- Deterministic Swift Testing coverage, API inventory, schema verification, and
  opt-in real Codex binary validation.

[Unreleased]: https://github.com/swift-library/swift-codex/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/swift-library/swift-codex/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/swift-library/swift-codex/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/swift-library/swift-codex/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/swift-library/swift-codex/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/swift-library/swift-codex/releases/tag/v0.1.0
