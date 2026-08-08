# CodexMCP Protocol Invariants

## Startup

- The requested protocol version comes from `CodexMCPClientInfo`.
- The wire initialize request carries that exact version.
- A different response version is a protocol failure.
- Client name and version are caller-supplied, never library placeholders.
- Failed startup cleans up the owned process and transport.

## Correlation

- Library-generated request IDs are monotonic `Int64` values.
- An active ID is never reused or overwritten.
- Fractional, out-of-range, or precision-losing response IDs are rejected.
- Responses for unknown active IDs fail the connection.
- Tool events and approval requests must correlate to one active tool call.
- Duplicate approval IDs or multiple simultaneous approval mappings for one
  call are protocol failures.

## Completion

- Success, failure, cancellation, stop, transport close, and process exit each
  complete pending result and approval continuations at most once.
- Streams finish before shutdown returns.
- Late cancellation of an already completed request is a non-fatal no-op.
- A caller may answer a pending approval only once.

## Diagnostics

- JSON-RPC errors preserve code, message, and optional data.
- Stderr is drained continuously to prevent pipe backpressure.
- Diagnostic stderr is bounded and redacts bearer credentials, API keys,
  tokens, secrets, and passwords.
- Tool argument payloads and credentials are not copied into diagnostics.

## Product Boundary

The public API contains CodexMCP-owned request, result, event, approval, ID,
JSON, lifecycle, and error types. It does not expose the underlying MCP SDK,
SystemPackage, process handles, continuations, channels, or routing state.
