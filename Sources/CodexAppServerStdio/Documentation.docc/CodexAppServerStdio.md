# ``CodexAppServerStdio``

Launch and connect to a local `codex app-server` process over stdio.

## Overview

The stdio transport owns executable discovery, optional version validation,
process launch, newline-delimited message framing, and process cleanup. It
implements the schema-independent runtime transport without importing generated
protocol models.

## Topics

### Transport and configuration

- ``CodexAppServerStdioTransport``
- ``CodexAppServerStdioConfiguration``
- ``CodexAppServerStdioBinaryVersionRequirement``
- ``CodexAppServerStdioError``
