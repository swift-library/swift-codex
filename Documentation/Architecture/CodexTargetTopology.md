# Target Topology

The public SwiftPM products are:

- `Codex`
- `CodexExec`
- `CodexMCP`
- `CodexAppServerProtocol`
- `CodexAppServerRuntime`
- `CodexAppServerClient`
- `CodexAppServerStdio`
- `CodexAppServerURLSession`
- `CodexAppServerNIO`
- `CodexAppServerVapor`
- `CodexAppServerHummingbird`

The schema generator executable target and its build and command plugins are
package tools, not public executable products. `CodexAppServerTestingSupport`
is a package test-support target, not a product. `_CodexProcess` is private to
the package and owns native child-process and pipe lifetimes shared by Exec, Stdio, and CodexMCP. It has no protocol models, host policy, or public product.
Native completion supports asynchronous callers and synchronous version probes
without depending on the caller's executor. Windows uses suspended Job Object
admission; macOS uses a separate process group and retains the unreaped root PID
until group termination is confirmed. Stdio owns the version-probe deadline,
output budget and public failure mapping.

Dependency direction:

```text
Codex -> CodexExec
CodexExec -> _CodexProcess

CodexAppServerClient -> Protocol + Runtime
CodexAppServerProtocol -> Runtime
Stdio / URLSession / NIO / Vapor / Hummingbird -> Runtime
Stdio -> _CodexProcess

CodexMCP -> MCP SDK + Swift System + _CodexProcess
```

Generated protocol models do not depend on concrete transports. Concrete
transports implement `CodexAppServerMessageTransport` and do not own schema,
request correlation, application policy, authentication storage, or audit.

Gateway, responder, policy, and test-contract libraries are not products of
this package.
