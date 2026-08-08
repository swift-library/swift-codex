import CodexAppServerRuntime
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import NIOWebSocket

public enum CodexAppServerHummingbirdError: Error, Equatable, Sendable {
  case closed
  case invalidUTF8
}

public enum CodexAppServerHummingbird {
  @discardableResult
  public static func webSocket<Routes: RouterMethods>(
    on routes: Routes,
    _ path: RouterPath = "",
    maxMessageSize: Int = .max,
    shouldUpgrade:
      @Sendable @escaping (Request, Routes.Context) async throws -> RouterShouldUpgrade = {
        _, _ in .upgrade([:])
      },
    onConnect:
      @escaping @Sendable (Request, Routes.Context, any CodexAppServerMessageTransport) async ->
      Void
  ) -> Routes where Routes.Context: WebSocketRequestContext {
    routes.ws(
      path,
      shouldUpgrade: shouldUpgrade
    ) { inbound, outbound, context in
      let transport = CodexAppServerHummingbirdWebSocketTransport(
        inbound: inbound,
        outbound: outbound,
        maxMessageSize: maxMessageSize
      )
      await onConnect(context.request, context.requestContext, transport)
      await transport.close()
    }
  }
}

public final class CodexAppServerHummingbirdWebSocketTransport:
  CodexAppServerMessageTransport,
  @unchecked Sendable
{
  public let inboundMessages: AsyncThrowingStream<String, Error>

  private let webSocket: any CodexAppServerHummingbirdWebSocket
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  private let state: CodexAppServerHummingbirdTransportState
  private let receiveTask: Task<Void, Never>

  public convenience init(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    maxMessageSize: Int = .max
  ) {
    self.init(
      webSocket: CodexAppServerHummingbirdWebSocketSession(
        inbound: inbound,
        outbound: outbound,
        maxMessageSize: maxMessageSize
      )
    )
  }

  init(webSocket: any CodexAppServerHummingbirdWebSocket) {
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let state = CodexAppServerHummingbirdTransportState()

    self.webSocket = webSocket
    self.inboundChannel = inboundChannel
    self.state = state
    self.inboundMessages = inboundChannel.stream
    self.receiveTask = Task { [webSocket, inboundChannel, state] in
      do {
        try await Self.receiveMessages(
          from: webSocket,
          into: inboundChannel,
          state: state
        )
      } catch is CancellationError {
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
        await state.markClosed()
        await webSocket.closeSocket()
      }
    }
  }

  public func sendMessage(_ message: String) async throws {
    try await state.checkOpen()
    try await webSocket.sendText(message)
  }

  public func close() async {
    guard await state.close() else {
      return
    }

    receiveTask.cancel()
    await webSocket.closeSocket()
    inboundChannel.finish()
  }

  private static func receiveMessages(
    from webSocket: any CodexAppServerHummingbirdWebSocket,
    into inboundChannel: CodexAppServerAsyncThrowingChannel<String>,
    state: CodexAppServerHummingbirdTransportState
  ) async throws {
    try await webSocket.receiveMessages { message in
      switch message {
      case .text(let text):
        inboundChannel.yield(text)
      case .binary(let buffer):
        inboundChannel.yield(try string(from: buffer))
      }
    }

    await state.markClosed()
    inboundChannel.finish()
  }

  private static func string(from buffer: ByteBuffer) throws -> String {
    var data = buffer
    let bytes = data.readBytes(length: data.readableBytes) ?? []
    guard let message = String(data: Data(bytes), encoding: .utf8) else {
      throw CodexAppServerHummingbirdError.invalidUTF8
    }
    return message
  }
}

protocol CodexAppServerHummingbirdWebSocket: Sendable {
  func receiveMessages(_ body: @Sendable (WebSocketMessage) async throws -> Void) async throws
  func sendText(_ text: String) async throws
  func closeSocket() async
}

private struct CodexAppServerHummingbirdWebSocketSession: CodexAppServerHummingbirdWebSocket {
  let inbound: WebSocketInboundStream
  let outbound: WebSocketOutboundWriter
  let maxMessageSize: Int

  func receiveMessages(_ body: @Sendable (WebSocketMessage) async throws -> Void) async throws {
    for try await message in inbound.messages(maxSize: maxMessageSize) {
      try await body(message)
    }
  }

  func sendText(_ text: String) async throws {
    try await outbound.write(.text(text))
  }

  func closeSocket() async {
    try? await outbound.close(.normalClosure, reason: nil)
  }
}

private actor CodexAppServerHummingbirdTransportState {
  private var isClosed = false

  func checkOpen() throws {
    if isClosed {
      throw CodexAppServerHummingbirdError.closed
    }
  }

  func close() -> Bool {
    if isClosed {
      return false
    }

    isClosed = true
    return true
  }

  func markClosed() {
    isClosed = true
  }
}
