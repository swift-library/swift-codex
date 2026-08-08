# Changelog

All notable changes to `swift-codex` are documented in this file. The project
follows [Semantic Versioning](https://semver.org/) beginning with `0.1.0`.

## [Unreleased]

## [0.1.0] - 2026-08-08

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

[Unreleased]: https://github.com/swift-library/swift-codex/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/swift-library/swift-codex/releases/tag/v0.1.0
