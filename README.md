# swift-codex

[![Swift Package](https://github.com/swift-library/swift-codex/actions/workflows/swift-package.yml/badge.svg)](https://github.com/swift-library/swift-codex/actions/workflows/swift-package.yml)

`swift-codex` is a Swift package for integrating with upstream Codex from
Swift code.

The package exposes upstream-aligned products:

| Product family | Use it for |
| --- | --- |
| `Codex` | Swift-native thread and turn interfaces backed by `CodexExec`. |
| `CodexExec` | Direct `codex exec` / `codex exec resume` process integration, raw stdout line streams, and JSONL protocol decoding. |
| `CodexAppServerProtocol` | Generated stable and experimental Codex AppServer protocol models. |
| `CodexAppServerRuntime` | Schema-agnostic AppServer request ids, raw envelopes, and message transport protocols. |
| `CodexAppServerClient` | Generated upstream-facing AppServer client bindings and connection lifecycle. |
| `CodexAppServerStdio` | Local `codex app-server --listen stdio://` process transport. |
| `CodexAppServerURLSession` | Foundation URLSession WebSocket client transport for AppServer endpoints. |
| `CodexAppServerNIO` | SwiftNIO WebSocket client transport for AppServer endpoints. |
| `CodexAppServerVapor` | Vapor downstream WebSocket server transport adapter for AppServer gateway compositions. |
| `CodexAppServerHummingbird` | Hummingbird downstream WebSocket server transport adapter for AppServer gateway compositions. |
| `CodexMCP` | `codex mcp-server` integration through MCP tool calls, server messages, approvals, and cancellation. |

The product families intentionally remain separate. Use the narrowest product
that matches the integration boundary you need.

## CodexAppServer Mental Model

`CodexAppServer` is not a single SwiftPM product. It is a role-product family:

- use `CodexAppServerProtocol` for generated stable and experimental protocol
  models
- use `CodexAppServerClient` for upstream-facing typed calls and app-server
  lifecycle
- use `CodexAppServerStdio`, `CodexAppServerURLSession`, or
  `CodexAppServerNIO` as upstream client transports
- use `CodexAppServerVapor` or `CodexAppServerHummingbird` as downstream
  WebSocket server transport adapters
- use `CodexAppServerRuntime` for schema-agnostic message transport and raw
  envelope seams when building a gateway

The common local-client shape is:

```text
app code
  -> CodexAppServerClient
  -> CodexAppServerStdio
  -> upstream codex app-server
```

The common server/gateway shape is:

```text
downstream client
  -> CodexAppServerVapor / CodexAppServerHummingbird
  -> your gateway session, policy, audit, or AOP
  -> CodexAppServerStdio / CodexAppServerURLSession / CodexAppServerNIO
  -> upstream codex app-server
```

Gateway policy is intentionally application-owned. The package supplies
transport adapters, generated protocol models, runtime message seams, and typed
client bindings; it does not publish a `CodexAppServerGateway` product.

## Requirements

- macOS 14 or newer
- Swift 6.2 or newer
- an upstream `codex` executable on `PATH`, or an explicit executable path in
  the relevant launch options
- upstream Codex authentication and environment configured for the capability
  you are invoking

The AppServer protocol and client bindings are generated from the vendored
upstream schema during normal SwiftPM builds. Generated Swift output is not
checked into the repository.

## Add The Package

```swift
// Package.swift
dependencies: [
  .package(
    url: "https://github.com/swift-library/swift-codex.git",
    .upToNextMinor(from: "0.1.0")
  ),
],
targets: [
  .target(
    name: "YourTarget",
    dependencies: [
      .product(name: "Codex", package: "swift-codex"),
    ]
  ),
]
```

Swap the product dependency to `CodexExec`, `CodexMCP`, or the narrow
CodexAppServer role products when you need one of those lower-level integration
boundaries directly. For local AppServer stdio use, depend on
`CodexAppServerClient` and `CodexAppServerStdio`.

## Stability

`swift-codex` follows Semantic Versioning beginning with `0.1.0`. During the
`0.x` series, minor releases may refine public APIs as upstream Codex contracts
evolve; patch releases remain source-compatible. Experimental AppServer models
track the pinned upstream experimental schema and do not carry the same
stability expectations as the stable namespace.

Every release pins its vendored AppServer schema to an exact upstream Codex
commit and tag. See
[`upstream.lock.json`](Vendor/CodexAppServerProtocolSchema/upstream.lock.json)
for the active provenance and [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## Quick Start

```swift
import Codex

func runCodex() async throws {
  let codex = Codex()
  let thread = codex.startThread()
  let turn = try await thread.run(.text("Summarize this repository."))

  print(turn.finalResponse)
}
```

For streaming SDK events:

```swift
import Codex

func streamCodex() async throws {
  let codex = Codex()
  let thread = codex.startThread()
  let streamedTurn = try await thread.runStreamed(.text("Inspect Package.swift."))

  for try await event in streamedTurn {
    print(event)
  }
}
```

## Usage Guides

- [Codex SDK usage](Documentation/Usage/Codex/README.md)
- [CodexExec usage](Documentation/Usage/CodexExec/README.md)
- [CodexAppServer usage](Documentation/Usage/CodexAppServer/README.md)
- [CodexMCP usage](Documentation/Usage/CodexMCP/README.md)

## Documentation

- [Documentation index](Documentation/README.md)
- [Architecture](Documentation/Architecture/README.md)
- [Generated reference artifacts](Documentation/Reference/README.md)
- [Release process](RELEASING.md)
