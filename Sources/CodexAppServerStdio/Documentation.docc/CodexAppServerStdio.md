# ``CodexAppServerStdio``

Launch and connect to a local `codex app-server` process over stdio.

## Overview

The stdio transport owns executable discovery, optional version validation,
process launch, newline-delimited message framing, and process cleanup. It
implements the schema-independent runtime transport without importing generated
protocol models.

An explicit executable URL takes precedence over PATH lookup. Windows lookup uses
semicolon-separated PATH entries, case-insensitive environment names and native
`.exe` files. It accepts quoted directory entries and does not select command
scripts through PATHEXT. Empty entries do not search the current directory. An
explicit environment replaces the inherited environment, including PATH.

Optional version validation is synchronous and uses the configured deadline,
which must be finite, positive and at most 60 seconds. It closes stdin, drains
stdout and stderr concurrently, and retains at most 64 KiB from each stream.
Excess output fails explicitly rather than accepting a truncated version match.
Timeout and output failure terminate the owned process and join both readers.

Windows processes belong to an invocation-specific Job Object. macOS processes
start in an owned process group. Root exit, close and cancellation terminate
remaining job or group members and join the original pipe operations. Cleanup
failures are reported by the inbound stream.

Frames are limited to 16 MiB before the newline. The inbound queue and the
combined queued/in-flight stdin writes each admit at most 256 messages and
16 MiB of payload. Incoming overflow terminates the owned process and joins its
readers. An outgoing admission failure leaves that frame unsent and preserves
already admitted work. Close rejects further admission, unblocks the current
native write through process termination and joins every admitted writer.
Call `close()` when finished with the transport, including after cancelling a
stream consumer.

## Topics

### Transport and configuration

- ``CodexAppServerStdioTransport``
- ``CodexAppServerStdioConfiguration``
- ``CodexAppServerStdioBinaryVersionRequirement``
- ``CodexAppServerStdioError``
