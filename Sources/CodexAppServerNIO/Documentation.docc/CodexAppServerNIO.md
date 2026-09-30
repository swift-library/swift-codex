# ``CodexAppServerNIO``

Connect to a Codex AppServer WebSocket endpoint with SwiftNIO.

## Overview

This module supplies an event-loop-backed WebSocket client transport with
explicit headers, frame handling, cancellation, and close semantics. It depends
only on the schema-independent AppServer runtime and its concrete networking
libraries.

Use `connect(url:)` for `ws` or `wss`, and `connect(unixSocketPath:)` for a
local Unix-domain listener. A Unix path must be absolute and fit NIO's platform
address limit; `requestURI` and `hostHeader` configure the HTTP upgrade. Unix
listeners still exchange WebSocket frames. Client text and pong frames use fresh
masking keys. The runtime's existing message-count and byte budgets apply to
received messages.

## Topics

### WebSocket transport

- ``CodexAppServerNIOTransport``
- ``CodexAppServerNIOConfiguration``
- ``CodexAppServerNIOHeader``
- ``CodexAppServerNIOError``
