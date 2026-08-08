import CodexAppServerRuntime
import NIOCore
import NIOPosix
import Testing
import Vapor

@testable import CodexAppServerVapor

@Suite("CodexAppServerVapor Transport")
struct CodexAppServerVaporTransportTests {
  @Test("route helper registers websocket route without schema policy")
  func routeHelperRegistersWebSocketRoute() async throws {
    try await withApplication { app in
      let route = CodexAppServerVapor.webSocket(on: app, "app-server") { _, _ in }

      #expect(route.description == "GET /app-server")
    }
  }

  @Test("transport bridges inbound text and outbound sends")
  func bridgesInboundTextAndOutboundSends() async throws {
    let webSocket = FakeVaporWebSocket()
    let transport = CodexAppServerVaporWebSocketTransport(webSocket: webSocket)

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
    let webSocket = FakeVaporWebSocket()
    let transport = CodexAppServerVaporWebSocketTransport(webSocket: webSocket)

    webSocket.yieldBinary(ByteBuffer(string: "binary"))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()

    #expect(message == "binary")
    await transport.close()
  }

  @Test("transport rejects invalid utf8 binary")
  func invalidUTF8BinaryIsRejected() async throws {
    let webSocket = FakeVaporWebSocket()
    let transport = CodexAppServerVaporWebSocketTransport(webSocket: webSocket)

    var buffer = ByteBufferAllocator().buffer(capacity: 1)
    buffer.writeBytes([0xff])
    webSocket.yieldBinary(buffer)

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerVaporError.invalidUTF8) {
      _ = try await iterator.next()
    }
  }

  @Test("transport close closes websocket and finishes inbound stream")
  func closeClosesWebSocketAndFinishesInboundStream() async throws {
    let webSocket = FakeVaporWebSocket()
    let transport = CodexAppServerVaporWebSocketTransport(webSocket: webSocket)

    await transport.close()

    #expect(await webSocket.isClosed)
    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()
    #expect(message == nil)
    await #expect(throws: CodexAppServerVaporError.closed) {
      try await transport.sendMessage("late")
    }
  }
}

private func withApplication(
  _ body: (Application) async throws -> Void
) async throws {
  let app = try await Application.make(.testing)
  do {
    try await body(app)
    try await app.asyncShutdown()
  } catch {
    try? await app.asyncShutdown()
    throw error
  }
}

private final class FakeVaporWebSocket: CodexAppServerVaporWebSocket, @unchecked Sendable {
  private let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
  private let state = FakeVaporWebSocketState()
  private let lock = NSLock()
  private var onTextCallback: (@Sendable (CodexAppServerVaporWebSocket, String) -> Void)?
  private var onBinaryCallback: (@Sendable (CodexAppServerVaporWebSocket, ByteBuffer) -> Void)?
  private lazy var onClosePromise = eventLoop.makePromise(of: Void.self)

  var onClose: EventLoopFuture<Void> {
    onClosePromise.futureResult
  }

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

  func setTextHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, String) -> Void
  ) {
    lock.lock()
    onTextCallback = callback
    lock.unlock()
  }

  func setBinaryHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, ByteBuffer) -> Void
  ) {
    lock.lock()
    onBinaryCallback = callback
    lock.unlock()
  }

  func sendText(_ text: String) async throws {
    try await state.record(text)
  }

  func closeSocket() async {
    await state.close()
    onClosePromise.succeed(())
  }

  func yieldText(_ text: String) {
    lock.lock()
    let callback = onTextCallback
    lock.unlock()
    callback?(self, text)
  }

  func yieldBinary(_ buffer: ByteBuffer) {
    lock.lock()
    let callback = onBinaryCallback
    lock.unlock()
    callback?(self, buffer)
  }
}

private actor FakeVaporWebSocketState {
  private(set) var sentText: [String] = []
  private(set) var isClosed = false

  func record(_ text: String) throws {
    if isClosed {
      throw CodexAppServerVaporError.closed
    }

    sentText.append(text)
  }

  func close() {
    isClosed = true
  }
}
