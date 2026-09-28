# ``CodexAppServerRuntime``

Build schema-independent Codex AppServer sessions and transports.

## Overview

This module owns raw envelopes, request identifiers, and transport protocols.
Connection correlation and stream channels remain package implementation
details. The module does not import generated AppServer models or concrete
transport implementations.

Stdio framing accepts at most 16 MiB of UTF-8 bytes before each newline, including
an optional carriage return. Partial frames are checked before buffer growth.
An oversized frame throws `FoundationError.messageTooLarge`.

Package-owned inbound channels retain at most 256 messages and 16 MiB of original
wire payload per channel. Consumption releases capacity. Overflow throws
`FoundationError.bufferLimitExceeded`, releases the invalidated backlog and
terminates the stream; it never silently drops one message and continues. These
are wire-retention budgets, not exact decoded-object heap measurements. Transport
frameworks may impose additional frame limits.

## Topics

### Transport seams

- ``CodexAppServerMessageTransport``
- ``CodexAppServerLinePeer``

### Correlation and envelopes

- ``CodexAppServerConnectionFoundation``
