# ``CodexAppServerNIO``

Connect to a Codex AppServer WebSocket endpoint with SwiftNIO.

## Overview

This module supplies an event-loop-backed WebSocket client transport with
explicit headers, frame handling, cancellation, and close semantics. It depends
only on the schema-independent AppServer runtime and its concrete networking
libraries.

## Topics

### WebSocket transport

- ``CodexAppServerNIOTransport``
- ``CodexAppServerNIOConfiguration``
- ``CodexAppServerNIOHeader``
- ``CodexAppServerNIOError``
