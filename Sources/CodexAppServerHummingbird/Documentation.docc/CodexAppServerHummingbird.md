# ``CodexAppServerHummingbird``

Expose a downstream AppServer-compatible WebSocket route through Hummingbird.

## Overview

This server transport adapter bridges Hummingbird WebSocket frames to
`CodexAppServerRuntime`. It does not implement AppServer methods, upstream
forwarding, gateway policy, validation, redaction, or audit.

## Topics

### Server transport

- ``CodexAppServerHummingbird``
- ``CodexAppServerHummingbirdWebSocketTransport``
- ``CodexAppServerHummingbirdError``
