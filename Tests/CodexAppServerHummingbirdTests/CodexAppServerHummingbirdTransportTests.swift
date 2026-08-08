import CodexAppServerRuntime
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import HummingbirdWebSocket
import NIOCore
import Testing

@testable import CodexAppServerHummingbird

@Suite("CodexAppServerHummingbird Transport")
struct CodexAppServerHummingbirdTransportTests {
  @Test("route helper registers websocket route and bridges runtime transport")
  func routeHelperRegistersWebSocketRoute() async throws {
    let router = Router(context: BasicWebSocketRequestContext.self)
    CodexAppServerHummingbird.webSocket(on: router, "app-server") { _, _, transport in
      do {
        var iterator = transport.inboundMessages.makeAsyncIterator()
        if let message = try await iterator.next() {
          try await transport.sendMessage("echo:\(message)")
        }
      } catch {
        await transport.close()
      }
    }

    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(webSocketRouter: router)
    )

    _ = try await app.test(.live) { client in
      try await client.ws("/app-server") { inbound, outbound, _ in
        try await outbound.write(.text("hello"))

        var iterator = inbound.messages(maxSize: .max).makeAsyncIterator()
        let message = try await iterator.next()

        #expect(message == .text("echo:hello"))
      }
    }
  }

  @Test("transport bridges inbound text and outbound sends")
  func bridgesInboundTextAndOutboundSends() async throws {
    let webSocket = FakeHummingbirdWebSocket()
    let transport = CodexAppServerHummingbirdWebSocketTransport(webSocket: webSocket)

    webSocket.yieldText("hello")

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()
    try await transport.sendMessage("reply")

    #expect(message == "hello")
    #expect(await webSocket.sentText == ["reply"])
    await transport.close()
  }

  @Test("transport bridges inbound binary utf8")
  func bridgesInboundBinaryUTF8() async throws {
    let webSocket = FakeHummingbirdWebSocket()
    let transport = CodexAppServerHummingbirdWebSocketTransport(webSocket: webSocket)

    webSocket.yieldBinary(ByteBuffer(string: "binary"))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()

    #expect(message == "binary")
    await transport.close()
  }

  @Test("transport rejects invalid utf8 binary")
  func invalidUTF8BinaryIsRejected() async throws {
    let webSocket = FakeHummingbirdWebSocket()
    let transport = CodexAppServerHummingbirdWebSocketTransport(webSocket: webSocket)

    var buffer = ByteBufferAllocator().buffer(capacity: 1)
    buffer.writeBytes([0xff])
    webSocket.yieldBinary(buffer)

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerHummingbirdError.invalidUTF8) {
      _ = try await iterator.next()
    }
  }

  @Test("transport close closes websocket and finishes inbound stream")
  func closeClosesWebSocketAndFinishesInboundStream() async throws {
    let webSocket = FakeHummingbirdWebSocket()
    let transport = CodexAppServerHummingbirdWebSocketTransport(webSocket: webSocket)

    await transport.close()

    #expect(await webSocket.isClosed)
    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()
    #expect(message == nil)
    await #expect(throws: CodexAppServerHummingbirdError.closed) {
      try await transport.sendMessage("late")
    }
  }
}

private final class FakeHummingbirdWebSocket: CodexAppServerHummingbirdWebSocket,
  @unchecked Sendable
{
  private let inboundChannel = CodexAppServerAsyncThrowingChannel<WebSocketMessage>()
  private let state = FakeHummingbirdWebSocketState()

  var sentText: [String] {
    get async {
      await state.sentText
    }
  }

  var isClosed: Bool {
    get async {
      await state.isClosed
    }
  }

  func receiveMessages(_ body: @Sendable (WebSocketMessage) async throws -> Void) async throws {
    for try await message in inboundChannel.stream {
      try await body(message)
    }
  }

  func sendText(_ text: String) async throws {
    try await state.record(text)
  }

  func closeSocket() async {
    await state.close()
    inboundChannel.finish()
  }

  func yieldText(_ text: String) {
    inboundChannel.yield(.text(text))
  }

  func yieldBinary(_ buffer: ByteBuffer) {
    inboundChannel.yield(.binary(buffer))
  }
}

private actor FakeHummingbirdWebSocketState {
  private(set) var sentText: [String] = []
  private(set) var isClosed = false

  func record(_ text: String) throws {
    if isClosed {
      throw CodexAppServerHummingbirdError.closed
    }

    sentText.append(text)
  }

  func close() {
    isClosed = true
  }
}
