# ``Codex``

Use Codex through SDK-style Swift threads and streamed or buffered turns.

## Overview

The `Codex` module is the highest-level product in `swift-codex`. It translates
thread and turn operations onto the upstream non-interactive Codex process
contract while preserving cancellation, streamed events, and session identity.

Use ``CodexThread`` when an application wants a stateful Swift object. Choose
the lower-level `CodexExec` product when direct process arguments and JSONL
events are the desired integration boundary.

## Topics

### Starting a session

- ``CodexThread``
- ``ThreadOptions``
- ``TurnOptions``

### Turn results

- ``StreamedTurn``
- ``Turn``
- ``Input``
