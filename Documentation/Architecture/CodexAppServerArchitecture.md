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
the source of truth for generated typed wrappers, excluded raw methods, public
method inventory, documentation, and the schema-refresh API diff. Initialize,
deprecated fuzzy-file search, and unadopted fuzzy sessions do not receive
public wrappers.

Stable and experimental namespaces are separate. Experimental methods already
present in stable are not duplicated as client wrappers. Object unions inherit
sibling properties and required fields into each inline branch; conflicting or
unsupported shared constraints fail generation rather than dropping fields.
Explicit experimental server-request adoption is recorded in the same manifest.

## Client Semantics

The connection generates request IDs unless an internal typed path needs an
explicit ID. Duplicate active IDs fail immediately and cannot replace a
pending response. JSON-RPC IDs preserve string and `Int64` forms. Error
responses preserve code, message, and optional data.

The default inbound mode provides an ordered `notifications` stream containing
the generated `Stable.ServerNotification` enum and a `typedServerRequests`
stream. A session configured with `inboundMessageMode: .raw` instead provides
`rawNotifications` and `rawServerRequests`, preserving complete JSON envelopes
without decoding their method-specific payloads. Inactive streams finish
immediately. Each stream has one consumer; events are not duplicated across
representations. Use `.rawOrdered` and `rawInboundMessages` when notification
and server-request causality must be preserved together. Its messages reuse the
same raw values and connection-owned request handles. The split raw and typed
streams are inactive in this mode, so unread copies cannot accumulate. The
consumer can register a request before processing a following completion
notification and dispatch its response work separately. RPC response correlation
remains connection-owned and is not delivered as a second public message.

`sendRawRequest` accepts adopted methods and preserves complete JSON params
and results, including fields beyond the pinned model. Explicitly excluded
methods and the initialize/initialized lifecycle remain unavailable through
raw access. Typed methods continue to provide the pinned generated contract;
clients forwarding experimental or newer fields use the raw representation.
Typed and raw server-request handles bind the receiving connection, request ID
and admission token; completion or rejection is allowed once through that
connection. Reusing an ID does not authorize an old handle to complete new work. Unknown
methods are delivered to the raw consumer for a response or explicit rejection.

In typed mode, unknown and experimental-only notifications produce value-free
observations; unadopted server requests receive JSON-RPC -32601. Observations
retain the latest 64 entries and at most 256 UTF-8 bytes of each method name.
Known malformed payloads and invalid envelopes still fail the connection.
`currentTime/read` is an explicitly adopted experimental typed callback.
Experimental thread/turn start overlays preserve generated experimental params
with stable response types. Presence-sensitive update overloads distinguish
omitted, explicit null and replacement fields.

Closing, peer failure, malformed input, and cancellation complete every
pending response and stream once. Correlation state, pending-response objects,
channels, and binary-probe reports are package implementation details.

## Transport Boundaries

All transports implement `CodexAppServerMessageTransport`. Stdio owns process
resolution and launch. URLSession and NIO own outbound WebSocket clients. Vapor
and Hummingbird own server-framework adapters. Schema, client policy, auth
storage, gateway forwarding, payload audit and payload redaction remain with
their client or application owners. Transports bound and redact their own
process diagnostics.

NIO is implemented directly with SwiftNIO, NIOHTTP1, NIOWebSocket, and NIOSSL.
It does not depend directly on AsyncHTTPClient. TCP/TLS and Unix-domain clients
perform an HTTP WebSocket upgrade and mask outgoing text and pong frames.
Stdio retains a line-safe 64 KiB stderr diagnostic and redacts common credential
forms before reporting a nonzero or signalled natural exit. Native process
ownership, EOF completion, cancellation and joined cleanup remain independent
of diagnostic capture.

## Stability

Stable generated models and all public client wrappers are part of the package
API baseline. Experimental models track the pinned experimental schema and are
called out separately in release notes. Every schema refresh requires a sorted
API additions/removals report and full generator, build, test, DocC, and API
validation.
