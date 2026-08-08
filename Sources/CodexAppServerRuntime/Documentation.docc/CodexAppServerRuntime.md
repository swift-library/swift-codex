# ``CodexAppServerRuntime``

Build schema-independent Codex AppServer sessions and transports.

## Overview

This module owns raw envelopes, request identifiers, and transport protocols.
Connection correlation and stream channels remain package implementation
details. The module does not import generated AppServer models or concrete
transport implementations.

## Topics

### Transport seams

- ``CodexAppServerMessageTransport``
- ``CodexAppServerLinePeer``

### Correlation and envelopes

- ``CodexAppServerConnectionFoundation``
