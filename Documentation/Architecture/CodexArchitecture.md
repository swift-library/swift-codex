# Package Architecture

`swift-codex` provides Swift-native interfaces backed by Codex process and
protocol contracts. It ships eleven libraries in four capability families:

- `Codex` for thread and turn semantics.
- `CodexExec` for `codex exec`, process lifecycle, and JSONL decoding.
- `CodexMCP` for `codex mcp-server` tools, events, approvals, and cancellation.
- App Server Protocol, Runtime, Client, and five transport libraries.

The only cross-family implementation dependency is the deliberate one-way
`Codex -> CodexExec` edge. Exec remains the source of truth for process launch,
arguments, JSONL events, termination, and partial observations. Codex adds
stateful thread handles and buffered or streamed turn conveniences.

App Server models are generated from the vendored schema pinned in
`upstream.lock.json`. The method adoption manifest controls generated client
wrappers and raw access policy. Runtime owns schema-independent envelopes and
transport protocols; concrete transport libraries do not own client policy.

Each public product preserves its own protocol-number fidelity and error
context. The package does not publish a cross-product shared protocol core.

Changes to public API, the pinned schema, or product dependencies require
format, build, test, DocC, API, license, and repository-hygiene validation.
