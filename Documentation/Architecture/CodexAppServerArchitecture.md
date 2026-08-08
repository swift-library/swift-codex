# Codex App Server Libraries

## Product Roles

- `CodexAppServerProtocol` exposes generated stable and experimental models.
- `CodexAppServerRuntime` exposes schema-independent request IDs, raw
  envelopes, framing, and message-transport protocols.
- `CodexAppServerClient` owns initialize/initialized handshake, generated
  request wrappers, response correlation, notifications, and typed server
  requests.
- `CodexAppServerStdio`, `CodexAppServerURLSession`, and `CodexAppServerNIO`
  are upstream client transports.
- `CodexAppServerVapor` and `CodexAppServerHummingbird` adapt downstream
  WebSocket connections to the runtime transport protocol.

## Schema and Generation

Stable and experimental JSON Schema trees are vendored from the exact tag and
commit recorded in `Vendor/CodexAppServerProtocolSchema/upstream.lock.json`.
The lock records toolchain, provenance, per-file hashes, aggregate hashes, and
license locations. Ordinary builds generate Swift into plugin work directories
and never modify the vendored schema or repository sources.

`method-adoption.json` explicitly classifies every pinned client method. It is
the source of truth for generated typed wrappers, raw-method denial, public
method inventory, documentation, and the schema-refresh API diff. Initialize,
deprecated fuzzy-file search, and unadopted fuzzy sessions do not receive
public wrappers.

Stable and experimental namespaces are separate. Experimental methods already
present in stable are not duplicated as client wrappers.

## Client Semantics

The connection generates request IDs unless an internal typed path needs an
explicit ID. Duplicate active IDs fail immediately and cannot replace a
pending response. JSON-RPC IDs preserve string and `Int64` forms. Error
responses preserve code, message, and optional data.

Inbound consumers receive one ordered `notifications` stream containing the
generated `Stable.ServerNotification` enum and one `typedServerRequests`
stream. Server-request handles bind params, response type, and request ID;
completion or rejection is allowed once.

Closing, peer failure, malformed input, and cancellation complete every
pending response and stream once. Correlation state, pending-response objects,
channels, and binary-probe reports are package implementation details.

## Transport Boundaries

All transports implement `CodexAppServerMessageTransport`. Stdio owns process
resolution and launch. URLSession and NIO own outbound WebSocket clients. Vapor
and Hummingbird own server-framework adapters. Client policy, schema, auth
storage, gateway policy, audit, and redaction do not move into transport
targets.

NIO is implemented directly with SwiftNIO, NIOHTTP1, NIOWebSocket, and NIOSSL.
It does not depend directly on AsyncHTTPClient.

## Stability

Stable generated models and all public client wrappers are part of the package
API baseline. Experimental models track the pinned experimental schema and are
called out separately in release notes. Every schema refresh requires a sorted
API additions/removals report and full generator, build, test, DocC, and API
validation.
