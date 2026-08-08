# Usage

This directory is the user-facing usage layer for `swift-codex`.

Architecture docs define current truth. Usage docs show how to consume the
current public Swift products.

## Product Guide

| Product | Boundary | Start here |
| --- | --- | --- |
| `Codex` | SDK object layer over Codex turns and threads | [Codex](Codex/README.md) |
| `CodexExec` | `codex exec` / `resume` process and JSONL protocol layer | [CodexExec](CodexExec/README.md) |
| `CodexAppServer` | App Server protocol/client/runtime/transport product family | [CodexAppServer](CodexAppServer/README.md) |
| `CodexMCP` | MCP client for the upstream Codex MCP server | [CodexMCP](CodexMCP/README.md) |

## Common Runtime Requirements

- macOS 14 or newer
- Swift 6.2 or newer
- an upstream `codex` executable available through `PATH` or explicit launch
  configuration
- authentication and environment configured as required by upstream Codex

## Choosing A Product

Use `Codex` when application code wants Swift SDK semantics: start or resume a
thread, run a turn, stream events, or receive a buffered `Turn`.

Use `CodexExec` when code needs direct control of the non-interactive
`codex exec` process boundary, raw stdout lines, JSONL event decoding, process
termination, or exact argv-facing behavior.

Use `CodexAppServer` when code needs the app-server protocol family:
generated protocol artifacts, upstream-facing typed client bindings,
transport-independent runtime seams, stdio or WebSocket transports, notification
streams, server-initiated requests, and gateway composition building blocks.
There is no single `CodexAppServer` product to import; choose the role products
you need. Local clients usually depend on `CodexAppServerClient`,
`CodexAppServerProtocol`, and one upstream transport. Server/gateway apps add a
downstream transport adapter such as `CodexAppServerVapor` or
`CodexAppServerHummingbird` and keep forwarding, AOP, auth, audit, and
redaction policy in application code.

Use `CodexMCP` when code needs to talk to the upstream Codex MCP server and
handle MCP tool calls, streamed server messages, approval requests, and
cancellation.
