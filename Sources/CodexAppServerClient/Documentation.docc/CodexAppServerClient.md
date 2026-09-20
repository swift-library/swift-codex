# ``CodexAppServerClient``

Call an upstream Codex AppServer through typed bindings or complete JSON messages.

## Overview

This module performs the initialize/initialized handshake, request correlation,
notification streaming, server-request completion, and generated typed method
calls. Applications inject a transport from `CodexAppServerStdio`,
`CodexAppServerURLSession`, or `CodexAppServerNIO`.

Select `inboundMessageMode: .raw` for the complete `rawNotifications` and
`rawServerRequests` streams. Raw requests retain unknown JSON fields while the
client continues to own handshake, correlation, cancellation, and once-only
server-request responses. The default `.typed` mode retains the pinned stable
protocol contract. Consume each selected stream once.

## Topics

### Connections

- ``CodexAppServerClient``
- ``CodexAppServerConnection``
- ``CodexAppServerClientError``

### Server-initiated requests

- ``CodexAppServerTypedServerRequest``
- ``CodexAppServerRawServerRequest``
- ``CodexAppServerRawNotification``
