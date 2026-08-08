# Codex Library

## Role

`Codex` is the stateful thread-and-turn interface. It depends on `CodexExec`,
which remains responsible for process launch and JSONL protocol behavior.

## Public Model

- `Codex` creates or resumes `CodexThread` handles.
- `CodexThread.run` buffers events into `Turn`.
- `CodexThread.runStreamed` returns `StreamedTurn`.
- `Input` accepts text and local-image entries.
- `CodexOptions`, `ThreadOptions`, and `TurnOptions` separate client, thread,
  and per-turn configuration.
- Event, item, usage, and thread-error names are aliases to the canonical Exec
  models consumed by the thread API.

The public surface has one web-search option, `webSearchMode`. Output schemas
are per-turn values. Working directory, writable directories, approval mode,
sandbox mode, model, reasoning effort, network access, and config overrides are
forwarded to Exec without inventing a second execution contract.

## Lifecycle

A newly started thread has no public identifier until a `thread.started` event
is observed. A resumed thread keeps its explicit opaque identifier. Buffered
and streamed calls share the same event source and identity resolution.

Caller cancellation before terminal success throws `CancellationError` and
cancels owned execution. Cancellation observed after `turn.completed` does not
invalidate the completed result.

Production always executes through `CodexExecClient`. Package-scoped executor
and client injection exist for deterministic tests; simulated events and usage
values live only under `Tests/`.

## Boundaries

`Codex` does not own App Server, MCP, generic agent orchestration, or a second
process implementation. New process behavior belongs in `CodexExec` first.
