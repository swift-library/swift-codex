# Native Windows CodexMCP validation

Run on Windows with Swift 6.2.3 from a committed SDK checkout:

```powershell
./Tests/WindowsMCP/Validate.ps1
```

This check archives the exact SDK commit and builds the complete `CodexMCP`
product through a SwiftPM consumer. It resolves the SDK's versioned dependencies
and checks every selected dependency against the SDK shipping lock before testing.
The owning real-binary integration tests are copied byte-for-byte. Debug and
release exercise startup, ping, tool discovery and idempotent shutdown with the
native CLI version and archive/executable hashes in `codex-windows-binary.json`.
No login or model request is made.

The evidence directory `.build/windows-mcp/evidence` records the SDK source
revision/archive hash, original test hash, dependency locks, native CLI identity
and each configuration's result. The original shipping lock remains unchanged.
Use a fresh output directory for each run.

The MCP transport dependency owns its in-memory, HTTP and stdio regression
checks. This SDK check owns the `CodexMCP` integration with the real CLI. Separate
Windows checks exercise App Server/Exec process ownership and audit all eleven
SDK products. Native protocol success does not establish model authentication
or support for other network products.
