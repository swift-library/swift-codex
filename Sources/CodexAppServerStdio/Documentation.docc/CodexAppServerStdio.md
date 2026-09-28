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

`processIdentifier` identifies the launched root for diagnostics; it is not a
capability to adopt or signal a later process with the same numeric ID.
`waitForExit()` joins native cleanup and all pipe operations, returning the root's
exit code or POSIX signal. Concurrent observers share this lifetime, and cancelling
an observer does not terminate the process. The method throws when native cleanup
cannot be confirmed. Framing/read failures remain on `inboundLines`, independently
of successful process cleanup. Use `close()` to request termination.

`finishInput()` stops new writes, drains already accepted writes and delivers
stdin EOF without terminating the child or closing its output. Concurrent and
cancelled callers join the same input closure. It can remain blocked if the child
does not read input; callers with a shutdown deadline use `close()` to terminate
the process and join the blocked operations. Use `waitForExit()` to observe the
child's completion after EOF. Writes rejected after input closure do not interrupt
the child's remaining work.

Frames are limited to 16 MiB before the newline. Set `maximumMessageBytes` to a
positive value no larger than this ceiling to enforce a smaller incoming and
outgoing frame bound. The count includes any carriage return before the line feed.
Invalid bounds fail before executable discovery or process launch. The inbound queue and the
combined queued/in-flight stdin writes each admit at most 256 messages and
16 MiB of payload. Incoming overflow terminates the owned process and joins its
readers. An outgoing admission failure leaves that frame unsent and preserves
already admitted work. A native stdin failure terminates and joins the owned
process before returning the error. Close rejects further admission, unblocks the current
native write through process termination and joins every admitted writer.
Call `close()` when finished with the transport, including after cancelling a
stream consumer.

## Topics

### Transport and configuration

- ``CodexAppServerStdioTransport``
- ``CodexAppServerStdioConfiguration``
- ``CodexAppServerStdioBinaryVersionRequirement``
- ``CodexAppServerStdioError``
