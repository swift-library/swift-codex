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

Each selected inbound stream retains at most 256 messages and 16 MiB of original
wire payload. A slow consumer that exceeds either budget receives an explicit
`CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded` failure.
The connection fails pending replies, releases its backlog and closes its
transport. Reading notifications never suspends the protocol reader behind a
full queue, so replies cannot deadlock on notification consumption. Individual
messages larger than 16 MiB fail before JSON decoding. Use metadata and paged
history requests for long threads. Call `close()` when the connection is no
longer needed.

## Topics

### Connections

- ``CodexAppServerClient``
- ``CodexAppServerConnection``
- ``CodexAppServerClientError``

### Server-initiated requests

- ``CodexAppServerTypedServerRequest``
- ``CodexAppServerRawServerRequest``
- ``CodexAppServerRawNotification``

Select `inboundMessageMode: .rawOrdered` and consume `rawInboundMessages` to
observe notifications and server requests in their combined wire order. Each
message contains the complete raw notification or the existing connection-owned
request handle. Resolve or reject requests through that connection exactly once.
Other inbound streams finish immediately in this mode.
