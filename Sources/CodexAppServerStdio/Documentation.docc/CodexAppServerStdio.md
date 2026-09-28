# ``CodexAppServerStdio``

Launch and connect to a local `codex app-server` process over stdio.

## Overview

The stdio transport owns executable discovery, optional version validation,
process launch, newline-delimited message framing, and process cleanup. It
implements the schema-independent runtime transport without importing generated
protocol models.

An explicit executable URL takes precedence over PATH lookup. Windows lookup uses
semicolon-separated PATH entries, case-insensitive environment names and native
`.exe` files. It accepts quoted directory entries and does not select command
scripts through PATHEXT. Empty entries do not search the current directory. An
explicit environment replaces the inherited environment, including PATH.

## Topics

### Transport and configuration

- ``CodexAppServerStdioTransport``
- ``CodexAppServerStdioConfiguration``
- ``CodexAppServerStdioBinaryVersionRequirement``
- ``CodexAppServerStdioError``
