# CodexAppServer Usage

`CodexAppServer` is the Swift product family for the upstream
`codex app-server` protocol.

Use this product when your code needs:

- app-server handshake and lifecycle
- request/response correlation over Codex AppServer transports
- stable and experimental generated protocol models
- upstream-facing typed client bindings
- notification streams
- server-initiated request handling

The implemented modules are split by role:

| Module | Use |
| --- | --- |
| `CodexAppServerProtocol` | generated stable and experimental protocol artifacts |
| `CodexAppServerClient` | generated upstream-facing client bindings and connection lifecycle |
| `CodexAppServerRuntime` | schema-agnostic peer/session/runtime primitives |
| `CodexAppServerStdio` | stdio/process transport to an upstream app-server |
| `CodexAppServerURLSession` | Foundation URLSession WebSocket client transport |
| `CodexAppServerNIO` | SwiftNIO WebSocket client transport |
| `CodexAppServerVapor` | Vapor downstream WebSocket server transport adapter |
| `CodexAppServerHummingbird` | Hummingbird downstream WebSocket server transport adapter |

All accepted CodexAppServer role products are implemented. Lambda-style hosting
adapters remain outside current scope.

## User Mental Model

There is no umbrella `CodexAppServer` product. Pick the products that match the
role your process owns.

For a local Swift client:

```text
app code
  -> CodexAppServerClient
  -> CodexAppServerStdio
  -> upstream codex app-server
```

For a WebSocket-facing server or gateway:

```text
downstream app or browser
  -> CodexAppServerVapor / CodexAppServerHummingbird
  -> your gateway session
  -> CodexAppServerStdio / CodexAppServerURLSession / CodexAppServerNIO
  -> upstream codex app-server
```

`CodexAppServerVapor` and `CodexAppServerHummingbird` only accept downstream
WebSocket connections and expose them as `CodexAppServerMessageTransport`.
They do not own forwarding, auth, audit, redaction, policy, retry, replay, or
method-specific behavior.

Use `CodexAppServerClient` when the process itself is an upstream app-server
client. Do not use `CodexAppServerClient.start()` inside a transparent proxy
path, because that performs the gateway's own `initialize` handshake. A
transparent proxy should bridge downstream messages to upstream messages
directly.

## Dependency Matrix

Choose package products by scenario:

| Scenario | Products |
| --- | --- |
| Local typed app-server client over stdio | `CodexAppServerClient`, `CodexAppServerProtocol`, `CodexAppServerStdio` |
| Local typed app-server client over Foundation WebSocket | `CodexAppServerClient`, `CodexAppServerProtocol`, `CodexAppServerURLSession` |
| Local typed app-server client over SwiftNIO WebSocket | `CodexAppServerClient`, `CodexAppServerProtocol`, `CodexAppServerNIO` |
| Raw transport bridge or custom gateway session | `CodexAppServerRuntime` plus one downstream and one upstream transport |
| Vapor downstream gateway | `CodexAppServerRuntime`, `CodexAppServerVapor`, and the chosen upstream transport |
| Hummingbird downstream gateway | `CodexAppServerRuntime`, `CodexAppServerHummingbird`, and the chosen upstream transport |
| Message-level AOP or typed policy | `CodexAppServerRuntime`, `CodexAppServerProtocol`, and the chosen transport products |
| Tests that need reusable app-server fakes | internal test target `CodexAppServerTestingSupport`; it is not a public product |

Do not add a dependency on every AppServer product by default. Pull in only the
role products that your target actually owns.

## Generated Protocol Models

The protocol model source of truth is the vendored upstream schema under
`Vendor/CodexAppServerProtocolSchema/`.

SwiftPM runs the `CodexAppServerProtocolGenerator` build plugin for the
`CodexAppServerProtocol` and `CodexAppServerClient` targets and generates Swift
models and client bindings under the build directory. The public namespace is:

```swift
CodexAppServerProtocol.Stable
CodexAppServerProtocol.Experimental
```

Generated Swift output is not checked into the repository.

## Start A Connection

```swift
import CodexAppServerClient
import CodexAppServerStdio

func connect() async throws {
  let client = CodexAppServerClient(transportFactory: {
    try CodexAppServerStdioTransport()
  })
  let connection = try await client.start()

  await connection.close()
}
```

## Configure The Process

```swift
import CodexAppServerClient
import CodexAppServerStdio
import Foundation

func connectToExplicitBinary() async throws {
  let process = CodexAppServerStdioConfiguration(
    executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
    arguments: ["app-server", "--listen", "stdio://"],
    workingDirectoryURL: URL(fileURLWithPath: "/path/to/workspace")
  )
  let client = CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(name: "my_swift_app", title: "My Swift App", version: "1.0.0"),
      experimentalApi: true
    ),
    transportFactory: {
      try CodexAppServerStdioTransport(configuration: process)
    }
  )

  let connection = try await client.start()
  await connection.close()
}
```

## Connect Over URLSession WebSocket

```swift
import CodexAppServerClient
import CodexAppServerURLSession
import Foundation

func connectToWebSocket(url: URL) async throws {
  let client = CodexAppServerClient(transportFactory: {
    CodexAppServerURLSessionTransport(url: url)
  })
  let connection = try await client.start()

  await connection.close()
}
```

## Connect Over SwiftNIO WebSocket

```swift
import CodexAppServerClient
import CodexAppServerNIO
import Foundation

func connectToNIOWebSocket(url: URL) async throws {
  let client = CodexAppServerClient(transportFactory: {
    try await CodexAppServerNIOTransport.connect(url: url)
  })
  let connection = try await client.start()

  await connection.close()
}
```

## Accept Downstream Vapor WebSockets

```swift
import CodexAppServerRuntime
import CodexAppServerStdio
import CodexAppServerVapor
import Vapor

func registerAppServerRoute(_ app: Application) {
  CodexAppServerVapor.webSocket(on: app, "app-server") { _, downstream in
    do {
      let upstream = try CodexAppServerStdioTransport()
      await bridge(downstream: downstream, upstream: upstream)
    } catch {
      await downstream.close()
    }
  }
}
```

The Vapor product is a framework adapter for downstream WebSocket ingress. It
bridges WebSocket frames to `CodexAppServerRuntime` message transports and does
not know method schemas or forwarding policy.

## Accept Downstream Hummingbird WebSockets

```swift
import CodexAppServerHummingbird
import CodexAppServerRuntime
import CodexAppServerStdio
import Hummingbird
import HummingbirdWebSocket

func registerAppServerRoute(_ router: Router<BasicWebSocketRequestContext>) {
  CodexAppServerHummingbird.webSocket(on: router, "app-server") { _, _, downstream in
    do {
      let upstream = try CodexAppServerStdioTransport()
      await bridge(downstream: downstream, upstream: upstream)
    } catch {
      await downstream.close()
    }
  }
}
```

The Hummingbird product uses Hummingbird's WebSocket router/upgrade package and
bridges the accepted connection to `CodexAppServerRuntime`. It does not own
gateway forwarding, validation, or Codex method handling.

## Bridge Downstream To Upstream

A transparent server-side session connects two `CodexAppServerMessageTransport`
instances. The downstream side usually comes from Vapor or Hummingbird. The
upstream side can be stdio, URLSession WebSocket, or SwiftNIO WebSocket.

```swift
import CodexAppServerRuntime

func bridge(
  downstream: any CodexAppServerMessageTransport,
  upstream: any CodexAppServerMessageTransport
) async {
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      await pump(from: downstream, to: upstream)
    }
    group.addTask {
      await pump(from: upstream, to: downstream)
    }

    _ = await group.next()
    group.cancelAll()
    await downstream.close()
    await upstream.close()
  }
}

private func pump(
  from source: any CodexAppServerMessageTransport,
  to sink: any CodexAppServerMessageTransport
) async {
  do {
    for try await message in source.inboundMessages {
      try Task.checkCancellation()
      try await sink.sendMessage(message)
    }
  } catch {
    // The session owner should log and count failures. The bridge closes both
    // sides when either direction ends.
  }
}
```

This raw bridge preserves the downstream client's JSON-RPC lifecycle. It does
not decode app-server methods and does not create a second initialize handshake.

## Production Gateway Checklist

Before deploying a gateway around these transports, decide the application-owned
policy and operations pieces explicitly:

- authenticate downstream clients before accepting or forwarding messages
- bound connection count, message size, and per-session concurrency
- pin the upstream `codex` binary path or remote endpoint and validate its
  expected version in deployment
- run the opt-in real-binary smoke tests in the release environment when using
  local stdio
- log and count transport open, close, send failure, receive failure, and
  upstream launch failure events
- define AOP outcomes for forward, drop, rewrite, synthetic response, and hard
  session close
- preserve request id correlation whenever a rule needs response-side policy
- close both downstream and upstream transports when either side ends
- keep secrets, auth tokens, and sensitive payload fields out of logs unless a
  redaction rule has already run
- keep gateway replay, audit, tenant routing, and rate-limit state in the
  application, not in the transport adapters

## Add Message AOP

Message AOP belongs in the gateway session between the two transports:

```text
downstream transport
  -> inbound interceptor chain
  -> upstream transport
  -> outbound interceptor chain
  -> downstream transport
```

Keep matching cheap until a rule needs typed payloads. The recommended matcher
order is:

1. direction
2. JSON-RPC message kind
3. method, request id, or error code
4. typed params or result payload

```swift
import CodexAppServerRuntime

enum GatewayDirection: Sendable {
  case downstreamToUpstream
  case upstreamToDownstream
}

enum GatewayMessageAction: Sendable {
  case forward(String)
  case drop
  case respond(String)
}

func inspect(
  direction: GatewayDirection,
  message: String
) throws -> GatewayMessageAction {
  let envelope = try CodexAppServerConnectionFoundation.decodeLine(message)
  let raw = try envelope.classify()

  switch (direction, raw) {
  case (.downstreamToUpstream, .request(_, "fs/writeFile", _)):
    return .drop
  case (.upstreamToDownstream, .request(_, "item/permissions/requestApproval", _)):
    return .forward(message)
  case (.upstreamToDownstream, .notification("thread/turn/item/completed", _)):
    return .forward(message)
  case (.upstreamToDownstream, .failure(_, let error)) where error.code == -32001:
    return .forward(message)
  default:
    return .forward(message)
  }
}
```

Only decode generated payload types after a rule has matched the method:

```swift
import Foundation
import CodexAppServerProtocol
import CodexAppServerRuntime

func decodeParams<T: Decodable>(
  _ params: CodexAppServerConnectionFoundation.JSONValue?,
  as type: T.Type
) throws -> T {
  let data = try JSONEncoder().encode(params ?? .null)
  return try JSONDecoder().decode(type, from: data)
}

func inspectThreadStart(
  params: CodexAppServerConnectionFoundation.JSONValue?
) throws {
  let typed = try decodeParams(
    params,
    as: CodexAppServerProtocol.Stable.ThreadStartParams.self
  )
  print(typed.cwd)
}
```

For response-side AOP, remember that JSON-RPC responses do not include a method.
Maintain a session-local request registry that records `id -> method` when a
request is forwarded, then resolve that id when the response returns.

```text
request id 42 -> thread/start
response id 42 -> thread/start response policy
```

AOP rule ownership should stay in application code:

- allowlists and denylists usually match `direction + method`
- audit and metrics usually match `direction + kind + method/errorCode`
- redaction and rewrite rules should decode generated payload types only after
  the raw method match succeeds
- notifications have no id and cannot receive JSON-RPC responses
- server-initiated requests have ids; rejecting one means writing a JSON-RPC
  error response back to the requester rather than forwarding it

## Consume Notifications

```swift
import CodexAppServerClient

func observeNotifications(connection: CodexAppServerConnection) async throws {
  for try await notification in connection.notifications {
    print(notification)
  }
}
```

The generated `ServerNotification` enum preserves every adopted notification
family in wire order. Switch on its cases when typed payload handling is needed.

## Handle Server-Initiated Requests

```swift
import CodexAppServerClient

func handleServerRequests(connection: CodexAppServerConnection) async throws {
  for try await request in connection.typedServerRequests {
    if case let .chatgptAuthTokensRefresh(handle) = request {
      try await connection.rejectServerRequest(
        handle,
        code: -32603,
        message: "Auth refresh is not implemented by this client."
      )
    }
  }
}
```

## Call Typed Methods

Typed method bindings live on `CodexAppServerConnection`. Parameter and return
types come from the generated stable or experimental namespaces.

Examples of supported method families include:

- thread lifecycle and history
- turn and review control
- command execution control
- filesystem access
- config, model, and account APIs
- MCP server APIs
- ecosystem surfaces such as apps and skills
- environment and admin APIs
- experimental realtime APIs

Prefer generated types over handwritten payload mirrors. Runtime code should
stay focused on connection, lifecycle, JSON-RPC correlation, streams, and
request resolution.

## Gateway Composition Best Practice

Gateway behavior is not a `swift-codex` foundation target. A gateway is a
business composition that receives downstream traffic, optionally inspects or
modifies Codex AppServer messages, and forwards to an upstream app-server.

Recommended shape:

```text
external client
  -> CodexAppServerVapor / CodexAppServerHummingbird
  -> gateway composition
  -> CodexAppServerClient
  -> CodexAppServerStdio / CodexAppServerURLSession / CodexAppServerNIO
  -> upstream codex app-server
```

Use typed protocol/client APIs only when the gateway needs message-level
interception, such as authorization, AOP, validation, redaction, audit, rewrite,
or compatibility mediation. A transparent proxy can stay closer to runtime raw
envelope forwarding.

`CodexAppServerVapor` and `CodexAppServerHummingbird` should remain transport
adapters. They should not know method schema such as `thread/start`, should
not own forwarding policy, and should not implement upstream app-server
business behavior.
