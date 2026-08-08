import CodexAppServerRuntime
import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import Testing

@testable import CodexAppServerNIO

@Suite("CodexAppServerNIO Transport")
struct CodexAppServerNIOTransportTests {
  @Test("transport emits inbound text frames")
  func emitsInboundTextFrames() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.yield(textFrame("hello"))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()

    #expect(message == "hello")
    await transport.close()
  }

  @Test("transport decodes inbound binary utf8 frames")
  func decodesInboundBinaryFrames() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.yield(binaryFrame("binary"))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()

    #expect(message == "binary")
    await transport.close()
  }

  @Test("transport sends outbound text frames")
  func sendsOutboundTextFrames() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    try await transport.sendMessage(#"{"jsonrpc":"2.0"}"#)

    let frame = try await webSocket.waitForSentFrame()
    #expect(frame.opcode == .text)
    #expect(string(from: frame) == #"{"jsonrpc":"2.0"}"#)
    await transport.close()
  }

  @Test("transport responds to ping frames with pong frames")
  func respondsToPingFrames() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.yield(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "ping")))

    let frame = try await webSocket.waitForSentFrame()
    #expect(frame.opcode == .pong)
    #expect(string(from: frame) == "ping")
    await transport.close()
  }

  @Test("transport close closes websocket and finishes inbound stream")
  func closeClosesWebSocketAndFinishesInboundStream() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    await transport.close()

    #expect(await webSocket.isClosed)
    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()
    #expect(message == nil)
    await #expect(throws: CodexAppServerNIOError.closed) {
      try await transport.sendMessage("late")
    }
  }

  @Test("transport remote close finishes inbound stream and rejects later sends")
  func remoteCloseFinishesInboundStreamAndRejectsSends() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.yield(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer()))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    let message = try await iterator.next()
    #expect(message == nil)
    await #expect(throws: CodexAppServerNIOError.closed) {
      try await transport.sendMessage("late")
    }
  }

  @Test("transport propagates receive failure through inbound stream")
  func receiveFailurePropagates() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.finish(throwing: CodexAppServerNIOError.upgradeRejected)

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerNIOError.upgradeRejected) {
      _ = try await iterator.next()
    }
  }

  @Test("transport rejects invalid utf8 frames")
  func invalidUTF8FramesAreRejected() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    var buffer = ByteBufferAllocator().buffer(capacity: 1)
    buffer.writeBytes([0xff])
    webSocket.yield(WebSocketFrame(fin: true, opcode: .binary, data: buffer))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerNIOError.invalidUTF8) {
      _ = try await iterator.next()
    }
  }

  @Test("transport rejects unsupported websocket frames")
  func unsupportedFramesAreRejected() async throws {
    let webSocket = FakeWebSocket()
    let transport = CodexAppServerNIOTransport(webSocket: webSocket)

    webSocket.yield(WebSocketFrame(fin: false, opcode: .continuation, data: ByteBuffer()))

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerNIOError.unsupportedFrame) {
      _ = try await iterator.next()
    }
  }

  @Test("connect rejects unsupported URL schemes before network I/O")
  func connectRejectsUnsupportedSchemes() async throws {
    let url = try #require(URL(string: "http://localhost/app-server"))

    await #expect(throws: CodexAppServerNIOError.unsupportedScheme("http")) {
      _ = try await CodexAppServerNIOTransport.connect(url: url)
    }
  }

  @Test("connect surfaces connector failures")
  func connectSurfacesConnectorFailures() async throws {
    let url = try #require(URL(string: "ws://localhost/app-server"))

    await #expect(throws: CodexAppServerNIOError.upgradeRejected) {
      _ = try await CodexAppServerNIOTransport.connect(
        url: url,
        eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
        configuration: .init(),
        connector: FailingConnector(error: CodexAppServerNIOError.upgradeRejected)
      )
    }
  }
}

private final class FakeWebSocket: CodexAppServerNIOWebSocket, @unchecked Sendable {
  let inboundFrames: AsyncThrowingStream<WebSocketFrame, Error>

  private let inboundChannel = CodexAppServerAsyncThrowingChannel<WebSocketFrame>()
  private let state = FakeWebSocketState()

  init() {
    inboundFrames = inboundChannel.stream
  }

  var isClosed: Bool {
    get async {
      await state.isClosed
    }
  }

  func sendFrame(_ frame: WebSocketFrame) async throws {
    try await state.record(frame)
  }

  func close() async {
    await state.close()
    inboundChannel.finish()
  }

  func yield(_ frame: WebSocketFrame) {
    inboundChannel.yield(frame)
  }

  func finish(throwing error: Error) {
    inboundChannel.finish(throwing: error)
  }

  func waitForSentFrame() async throws -> WebSocketFrame {
    try await state.waitForSentFrame()
  }
}

private actor FakeWebSocketState {
  private var sentFrames: [WebSocketFrame] = []
  private var waiters: [CheckedContinuation<WebSocketFrame, Error>] = []
  private(set) var isClosed = false

  func record(_ frame: WebSocketFrame) throws {
    if isClosed {
      throw CodexAppServerNIOError.closed
    }

    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume(returning: frame)
    } else {
      sentFrames.append(frame)
    }
  }

  func waitForSentFrame() async throws -> WebSocketFrame {
    if !sentFrames.isEmpty {
      return sentFrames.removeFirst()
    }
    if isClosed {
      throw CodexAppServerNIOError.closed
    }

    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func close() {
    isClosed = true
    let waiters = self.waiters
    self.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume(throwing: CodexAppServerNIOError.closed)
    }
  }
}

private struct FailingConnector: CodexAppServerNIOWebSocketConnector {
  var error: Error

  func connect(
    url: URL,
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration
  ) async throws -> any CodexAppServerNIOWebSocket {
    throw error
  }
}

private func textFrame(_ message: String) -> WebSocketFrame {
  WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: message))
}

private func binaryFrame(_ message: String) -> WebSocketFrame {
  WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(string: message))
}

private func string(from frame: WebSocketFrame) -> String? {
  var data = frame.data
  return data.readString(length: data.readableBytes)
}
