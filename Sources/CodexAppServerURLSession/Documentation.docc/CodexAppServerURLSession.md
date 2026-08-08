# ``CodexAppServerURLSession``

Connect to a Codex AppServer WebSocket endpoint with Foundation URLSession.

## Overview

This transport adapts URLSession WebSocket messages, close behavior, and
failures to `CodexAppServerRuntime`. Upstream remote WebSocket support is
experimental; applications remain responsible for endpoint authentication and
deployment policy.

## Topics

### WebSocket transport

- ``CodexAppServerURLSessionTransport``
- ``CodexAppServerURLSessionError``
