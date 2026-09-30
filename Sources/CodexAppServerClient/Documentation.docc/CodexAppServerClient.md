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

In typed mode, unknown or experimental-only notifications are summarized by
`unhandledInboundMessages`. Unadopted server requests receive JSON-RPC -32601
and a summary. This diagnostic stream retains the latest 64 entries, omits
parameter values and limits method names to 256 UTF-8 bytes. It is inactive in
raw modes. Known malformed payloads remain connection failures. The adopted
experimental `currentTime/read` callback has a typed response handle.

Typed and raw handles carry connection and admission ownership. A completed
handle cannot answer a later request reusing its ID. Experimental thread/turn
start overloads accept generated experimental params and return stable response
types. Presence-sensitive update overloads distinguish omission, null and value.

Each selected protocol inbound stream retains at most 256 messages and 16 MiB of original
wire payload. A slow consumer that exceeds either budget receives an explicit
`CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded` failure.
The connection fails pending replies, releases its backlog and closes its
transport. Reading notifications never suspends the protocol reader behind a
full queue, so replies cannot deadlock on notification consumption. Individual
messages larger than 16 MiB fail before JSON decoding. Use metadata and paged
history requests for long threads. Call `close()` when the connection is no
longer needed.

Pending client requests and cancelled requests awaiting a late reply share a
budget of 256 identifiers. Active server requests have an independent 256-slot
budget so full callback occupancy cannot consume client control slots. Both
directions share a total 16 MiB limit for retained identifier bytes. Cancelling
a request preserves its ID reservation until its late reply is consumed or the
connection closes; reusing that explicit ID fails before sending.

A client request that exceeds its budget fails without sending or cancelling
existing work. An otherwise valid server request exceeding its budget receives
a JSON-RPC error with code -32000 and acquires no ownership token. Admitted
callbacks and response correlation remain intact. Failure to send the rejection,
duplicate active server IDs and inbound stream overflow still fail the connection.
Responses and request completion release their reservations.

## Topics

### Connections

- ``CodexAppServerClient``
- ``CodexAppServerConnection``
- ``CodexAppServerClientError``

### Server-initiated requests

- ``CodexAppServerTypedServerRequest``
- ``CodexAppServerRawServerRequest``
- ``CodexAppServerRawNotification``
- ``CodexAppServerUnhandledInboundMessage``
- ``CodexAppServerThreadSectionAppearanceUpdate``
- ``CodexAppServerTurnServiceTierUpdate``

Select `inboundMessageMode: .rawOrdered` and consume `rawInboundMessages` to
observe notifications and server requests in their combined wire order. Each
message contains the complete raw notification or the existing connection-owned
request handle. Resolve or reject requests through that connection exactly once.
Other inbound streams finish immediately in this mode.
