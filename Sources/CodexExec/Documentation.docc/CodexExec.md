# ``CodexExec``

Run `codex exec` and `codex exec resume` through a typed Swift process boundary.

## Overview

`CodexExec` owns command construction, process launch, JSONL decoding, streamed
events, cancellation, termination interpretation, and preserved partial output.
It does not depend on AppServer or MCP products.

## Topics

### Launching Codex

- ``CodexExecClient``
- ``CodexExecRunRequest``
- ``CodexExecResumeRequest``
- ``CodexExecLaunchConfiguration``

### Protocol output

- ``CodexExecEvent``
- ``CodexExecItem``
- ``CodexExecError``
