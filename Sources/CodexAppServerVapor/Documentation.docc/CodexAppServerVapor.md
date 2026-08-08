# ``CodexAppServerVapor``

Expose a downstream AppServer-compatible WebSocket route through Vapor.

## Overview

This server transport adapter bridges Vapor WebSocket frames to
`CodexAppServerRuntime`. Gateway policy, forwarding, validation, authorization,
redaction, and audit remain application-owned composition concerns.

## Topics

### Server transport

- ``CodexAppServerVapor``
- ``CodexAppServerVaporWebSocketTransport``
- ``CodexAppServerVaporError``
