# CodexMCP Library

## Role

`CodexMCP` owns a typed Swift client for the upstream `codex mcp-server`
process. It supports startup, ping, tool discovery, Codex and reply tool calls,
server events, approvals, request cancellation, and deterministic shutdown.

## Public Model

Callers provide `CodexMCPClientInfo` with their real name, version, optional
title, and requested protocol version. `CodexMCPClient` is single-use after
stop and exposes explicit lifecycle state and startup metadata.

`runCodex` and `reply` return request-scoped handles. A handle owns its result,
server-message stream, approval-request stream, response function, and
cancellation function. Tool descriptions and results are converted to
CodexMCP-owned values; MCP SDK implementation types do not leak into public
API.

`CodexMCPRequestID` preserves string and `Int64` forms. `CodexMCPJSONValue`
distinguishes `Int64` and `Double`. JSON-RPC failures preserve code, message,
and optional data. Process failures may include bounded, redacted stderr
context.

## Ownership

The client launches one owned subprocess through the package-private native
process owner, continuously drains stderr, adapts
the SDK stdio transport, correlates outbound requests and inbound events, and
completes pending routes and approvals exactly once on success, cancellation,
transport close, process exit, or stop.

Shutdown joins the native process tree and stderr reader before releasing pipe
endpoints. Windows resolves a native `codex.exe` through the effective PATH and
bridges owned handle duplicates to MCP's CRT descriptor API. It never treats a
Win32 handle value as a descriptor. Environment overrides use native name identity.

The transport forwards each inbound frame when its consumer requests one, without
an intermediate forwarding queue. At most 256 outbound send correlations may be
pending. A single retained close task settles send observers and joins the base
transport; close callbacks run outside the MCP reader so client shutdown cannot
wait on its own task.

`CodexMCP` does not own App Server RPCs, Exec JSONL, arbitrary MCP resources or
prompts, a generic raw request API, or a shared cross-product runtime.

## Transport Dependency

The maintained MCP transport package is released from
[`computer-mcp/swift-sdk`](https://github.com/computer-mcp/swift-sdk).
`Package.swift` declares its exact release version and `Package.resolved`
records the source commit. The fork owns native Windows stdio and serialized
POSIX frame writes; Codex protocol and process ownership remain in this package.
Native Windows CodexMCP validation is documented in
[`Tests/WindowsMCP`](../../Tests/WindowsMCP/README.md).
