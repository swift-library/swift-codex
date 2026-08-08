# ``CodexMCP``

Integrate with the upstream `codex mcp-server` process.

## Overview

`CodexMCP` exposes Codex tool calls, server messages, approvals, cancellation,
and lifecycle control through the Model Context Protocol. It is independent of
the AppServer and direct Exec product families.

## Topics

### Client lifecycle

- ``CodexMCPClient``
- ``CodexMCPLaunchOptions``
- ``CodexMCPClientState``

### Calls and approvals

- ``CodexMCPRunRequest``
- ``CodexMCPCallHandle``
- ``CodexMCPApprovalRequest``
- ``CodexMCPApprovalDecision``
