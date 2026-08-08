# ``CodexAppServerProtocol``

Use generated stable and experimental Codex AppServer protocol models.

## Overview

The build-tool plugin derives this module's Swift models and method metadata
from the vendored, version-pinned upstream JSON Schema. Stable and experimental
types remain in separate namespaces. Generated Swift output is build-derived
and is not checked into the repository.

Choose `CodexAppServerClient` for typed requests and connection lifecycle. Use
this module directly when an integration needs the protocol models themselves.
