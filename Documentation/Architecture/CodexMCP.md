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

The client launches one owned subprocess, continuously drains stderr, adapts
the SDK stdio transport, correlates outbound requests and inbound events, and
completes pending routes and approvals exactly once on success, cancellation,
transport close, process exit, or stop.

`CodexMCP` does not own App Server RPCs, Exec JSONL, arbitrary MCP resources or
prompts, a generic raw request API, or a shared cross-product runtime.
