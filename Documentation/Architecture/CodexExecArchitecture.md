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

Approval and search options use native `approval_policy` and `web_search`
configuration overrides. Exec's headless approval semantics remain upstream-owned.
The source-compatible `fullAuto` property fails before execution when true,
because the pinned Codex version does not support that preset. Callers select
native sandbox and approval configuration explicitly.

The launcher concurrently drains stdout and stderr while writing stdin so
large streams cannot deadlock. It always owns the child's stdin pipe; an absent
payload closes that pipe to deliver EOF instead of inheriting the caller's input.
Caller cancellation terminates the owned child and waits for process exit and
all pipe readers/writers before returning. It remains distinguishable from an
upstream interruption or signal.

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

`CodexExecLaunchConfiguration.outputLimits` bounds process-level capture before
decoding: 8 MiB and 65,536 complete stdout lines, plus 1 MiB stderr by default.
The same stdout budget bounds cumulative stream delivery and retained output;
waiting without consuming the stream cannot create an unbounded queue. Readers
continue draining both pipes after the budget is exhausted. An oversized stdout
line is omitted as a whole, never decoded as a truncated JSON event. Retention
is a complete-line prefix, while stderr retains a byte prefix.

`CodexExecOutputCapture` reports omitted raw byte counts. A stdout overflow also
finishes its stream with `outputCaptureLimitExceeded`. After process termination,
an otherwise successful run with either stream incomplete throws that error
with its retained partial observation. Native failure or cancellation remains
the primary failure and carries the same missing-output metadata. Callers must
await termination even after a stdout stream error to observe process cleanup
and final stderr capture. These budgets limit output collection, not the child
process's memory or caller-owned copies.

## Boundaries

`CodexExec` does not own App Server models, MCP transport, stateful thread
handles, configuration-file editing, or a generic process framework.
