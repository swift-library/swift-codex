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

## Platform support

All eleven products support macOS 14 or newer. Windows x86_64 support follows the
product boundary below. The package's Apple deployment declarations do not make
all dependencies available on Windows.

| Products | Windows boundary |
| --- | --- |
| `CodexAppServerRuntime`, `CodexAppServerProtocol`, `CodexAppServerClient` | Native builds include the generated stable and experimental bindings. |
| `CodexExec`, `Codex`, `CodexAppServerStdio` | Native process execution with owned pipe handles, bounded framing/capture, explicit environment resolution and joined process-tree cleanup. |
| `CodexMCP` | Native MCP process integration through the versioned transport dependency; the upstream CLI must still provide `mcp-server`. |
| `CodexAppServerURLSession` | Native compilation is validated; Windows WebSocket lifecycle acceptance is not established by the process or MCP checks. |
| `CodexAppServerNIO` | Unavailable with the pinned NIOSSL dependency's Windows platform boundary. |
| `CodexAppServerVapor` | Unavailable with the pinned NIOExtras zlib dependency's Unix header requirements. |
| `CodexAppServerHummingbird` | Unavailable with the pinned Hummingbird environment implementation's platform boundary. |

The Windows build audit includes every public product and preserves individual
results, including unavailable dependencies. Every supported product must build
for the CI gate to pass. The three unavailable networking products are recorded
as dependency audits; their outcomes do not establish supported Windows behavior. Native runtime checks in
[`Tests/WindowsIntegration`](../../Tests/WindowsIntegration/README.md) exercise
App Server stdio and Exec ownership with process fixtures. The separate
[`Tests/WindowsMCP`](../../Tests/WindowsMCP/README.md) check consumes the shipping
dependency graph and a checksummed native Codex CLI. The native Windows CI uses
`windows-2022` and Swift 6.2.3.

Build results and native protocol tests do not establish model authentication.
The caller supplies vendor authentication and launch configuration. Upstream
Codex executables and their credentials are not distributed by this SDK.
