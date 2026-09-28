# MCP transport dependency candidate

This opt-in validation clones the complete upstream MCP Swift SDK at the revision
in `upstream.json`, reproduces its Windows EventSource import failure, and applies
the checksummed `windows-transports.patch`. The candidate supplies native Windows
stdio and selects the existing HTTP data path when EventSource is unavailable.
Existing Apple and Linux transport implementations are unchanged.

Run on Windows with Swift6.2.3:

```powershell
./Tests/DependencyCandidates/MCPTransport/Validate.ps1
```

Debug and release run unchanged upstream in-memory tests, native loopback HTTP
checks and the candidate's exact Windows stdio tests. Stdio verifies standard MCP
initialize/tool calls and exact integers, split UTF8 frames, malformed/truncated
input, queued count/byte bounds, blocked I/O deadlines/cancellation, concurrent
shutdown, queued-write cancellation and preserved caller-owned descriptors.
Native thread cancellation is joined before owned pipe duplicates are released.

A Python standard-library HTTP peer binds an ephemeral loopback port and is
joined by its creating run. The script records the complete source patch,
source/test hashes, dependency locks and native results under
`.build/mcp-transport-candidate/evidence`. Native stdio tests use actual Windows
pipes. They do not establish authenticated model or host private-IPC acceptance.

After transport acceptance, the script archives the exact SDK commit into a
separate source tree and compiles a consumer of the complete `CodexMCP` product
with the explicit MCP candidate. The unchanged owning real-binary tests run
against the pinned native Windows CLI in `codex-windows-binary.json`. Archive and
executable hashes are verified before execution. Startup, ping, tools/list and
idempotent stop run in debug and release; no login or model call is performed.
Source/test hashes and each candidate lock are retained separately from the
shipping lock, which must remain byte-identical.

This candidate does not change shipping dependency resolution or the independent
audit of all eleven SDK products. A release must explicitly adopt an upstream
fix or reviewed dependency distribution before claiming the Windows path.
