# CodexExec Library

## Role

`CodexExec` owns direct non-interactive execution through `codex exec` and
`codex exec resume`. It models arguments, process lifecycle, stdout/stderr,
JSONL events, termination, and partial observations.

## Requests and Launch

Run and resume are explicit request types. Supported options include prompt or
stdin input, images, working directory, writable directories, approval mode,
sandbox mode, model, search, output schema file, output-last-message file,
config overrides, and trusted-repository bypass.

Arguments are emitted in deterministic order. Session identifiers remain
opaque strings. Process environment and executable overrides are supplied by
`CodexExecLaunchConfiguration`.

The launcher concurrently drains stdout and stderr while writing stdin so
large streams cannot deadlock. Caller cancellation terminates the owned child
and remains distinguishable from an upstream interruption or signal.

## Output

Human-readable mode preserves stdout as text and stderr as diagnostics. JSONL
mode decodes thread, turn, item, completion, and failure events. Unknown event
and item kinds remain forward-compatible values with bounded raw JSON.

`CodexExecJSONValue` distinguishes `Int64` integers from `Double` values.
Unknown or MCP-related payloads therefore do not pass through a lossy common
number representation.

Successful JSONL execution requires exit status zero and a completed turn.
Failures preserve partial session, event, final-message, and stderr evidence
when available. Resume misses, malformed JSONL, output-file failures,
non-zero exits, interruption, launch failure, and cancellation remain distinct
`CodexExecError` cases.

## Boundaries

`CodexExec` does not own App Server models, MCP transport, stateful thread
handles, configuration-file editing, or a generic process framework.
