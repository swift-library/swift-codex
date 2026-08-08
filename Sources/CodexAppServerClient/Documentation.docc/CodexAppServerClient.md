# ``CodexAppServerClient``

Call an upstream Codex AppServer through generated typed Swift bindings.

## Overview

This module performs the initialize/initialized handshake, request correlation,
notification streaming, server-request completion, and generated typed method
calls. Applications inject a transport from `CodexAppServerStdio`,
`CodexAppServerURLSession`, or `CodexAppServerNIO`.

## Topics

### Connections

- ``CodexAppServerClient``
- ``CodexAppServerConnection``
- ``CodexAppServerClientError``

### Server-initiated requests

- ``CodexAppServerTypedServerRequest``
