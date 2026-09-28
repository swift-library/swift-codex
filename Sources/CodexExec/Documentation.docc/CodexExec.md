# ``CodexExec``

Run `codex exec` and `codex exec resume` through a typed Swift process boundary.

## Overview

`CodexExec` owns command construction, process launch, JSONL decoding, streamed
events, cancellation, termination interpretation, and preserved partial output.
It does not depend on AppServer or MCP products.

An explicit executable URL takes precedence over PATH lookup. On Windows, lookup
uses the configured case-insensitive PATH and selects `codex.exe` directly, with
semicolon-separated directory entries. An explicit environment replaces the
inherited environment. A configured API key replaces any existing environment
entry with the same native name; Windows compares names without case sensitivity.

## Topics

### Launching Codex

- ``CodexExecClient``
- ``CodexExecRunRequest``
- ``CodexExecResumeRequest``
- ``CodexExecLaunchConfiguration``
- ``CodexExecOutputLimits``

### Protocol output

- ``CodexExecEvent``
- ``CodexExecItem``
- ``CodexExecError``
- ``CodexExecOutputCapture``
