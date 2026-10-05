# Changelog

All notable changes to `swift-codex` are documented in this file. The project
follows [Semantic Versioning](https://semver.org/) beginning with `0.1.0`.

## [Unreleased]

### Added

- Typed experimental thread/turn start parameters with stable response contracts,
  presence-sensitive appearance and service-tier updates, plugin reconciliation,
  Bedrock discovery/setup, and a typed current-time server callback.
- Value-free, bounded observations for unhandled typed inbound methods; unknown
  server requests receive a method-not-found response without closing the session.
- Unix-domain WebSocket clients through NIO and bounded, redacted stderr
  diagnostics for natural unsuccessful App Server process exits.

### Fixed

- Preserve shared properties and required fields on generated object-union
  branches, including MCP elicitation scope and notification timestamps.
- Mask client WebSocket text and pong frames and bind typed callbacks to their
  receiving connection and admission generation, including reused request IDs.

### Changed

- swift-codex is now licensed under the Apache License 2.0 with the Swift Runtime
  Library Exception. Releases up to 0.4.1 remain available under the MIT License.
- The typed callback enum and transport error enums gain cases, and corrected
  generated models require upstream-mandated shared fields. These public changes
  require a minor release during `0.x`.

## [0.4.1] - 2026-09-29

### Fixed

- Adopt MCP `0.13.1-computer-mcp.1` so integer parameters and response values
  outside the signed Int range fail explicitly instead of acquiring a rounded
  identity through a Double fallback. Supported exact integers and finite
  fractions retain their representation across the native CodexMCP path.

## [0.4.0] - 2026-09-29

### Added

- Native Windows process and pipe ownership for Exec, App Server stdio and
  CodexMCP, with native executable/environment resolution and joined descendant
  cleanup.
- App Server stdio input completion, bounded frame configuration and joined
  process termination observations.

### Changed

- The new Windows execution capability and public Stdio lifecycle APIs advance
  the minor version during `0.x`. Existing macOS product boundaries remain.
- Adopt the exact versioned `computer-mcp/swift-sdk` transport fork for native
  Windows MCP stdio and complete POSIX frame serialization. Protocol authority
  remains in the upstream-aligned SDK products.

### Fixed

- Bound App Server and MCP buffering and request correlation while preserving
  duplex progress at callback capacity.
- Join version probes, failed native writes, process termination and transport
  retirement without retaining blocked pipe readers or request owners.

## [0.3.0] - 2026-09-27

### Added

- An ordered raw inbound mode combines notifications and server requests in
  native wire order while retaining connection-owned, once-only request handles.
  Existing typed and split raw streams keep their current behavior.

### Changed

- `InboundMessageMode` gains the `rawOrdered` case. Downstream exhaustive
  switches must handle it; this source compatibility change requires a minor
  release during `0.x`.

## [0.2.2] - 2026-09-21

### Fixed

- Stop the MCP transport before closing a released client's subprocess pipes,
  preserving descriptor ownership through process termination.
- Wait for tool requests to reach the MCP transport before returning their call
  handles, so immediate cancellation cannot overtake the original request.

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

[Unreleased]: https://github.com/swift-library/swift-codex/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/swift-library/swift-codex/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/swift-library/swift-codex/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/swift-library/swift-codex/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/swift-library/swift-codex/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/swift-library/swift-codex/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/swift-library/swift-codex/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/swift-library/swift-codex/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/swift-library/swift-codex/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/swift-library/swift-codex/releases/tag/v0.1.0
