# MCP HTTP dependency candidate

This opt-in validation clones the complete upstream MCP Swift SDK at the revision
in `upstream.json`, reproduces its Windows EventSource import failure, and applies
the checksummed platform-availability patch. The patch selects the existing HTTP
data path when EventSource is unavailable. Apple streaming behavior is unchanged;
SSE streaming and upstream Stdio are not supplied by this Windows correction.

Run on Windows with Swift 6.2.3:

```powershell
./Tests/DependencyCandidates/MCPHTTP/Validate.ps1
```

The script runs native loopback HTTP and unchanged upstream in-memory transport
tests in debug and release against the complete patched MCP library. A Python
standard-library peer binds an ephemeral loopback port and is joined by its
creating run. HTTP checks cover UTF-8 bodies, headers, session acquisition and
expiration, error propagation and disconnect. The script records source/test
hashes, dependency locks and native logs under `.build/mcp-http-candidate/evidence`.
These tests validate dependency behavior; they do not prove authenticated model
execution or adapter process/IPC support. The original upstream full test suite
also contains platform-specific Stdio tests, which this consumer does not run.

This candidate does not change shipping dependency resolution or the independent
audit of all eleven SDK products. A release must explicitly adopt an upstream
fix or a reviewed dependency distribution before claiming this Windows path.
