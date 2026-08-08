import CodexAppServerRuntime
import Foundation
import Vapor

public enum CodexAppServerVaporError: Error, Equatable, Sendable {
  case closed
  case invalidUTF8
}

public enum CodexAppServerVapor {
  @discardableResult
  public static func webSocket(
    on routes: RoutesBuilder,
    _ path: PathComponent...,
    maxFrameSize: WebSocketMaxFrameSize = .default,
    shouldUpgrade: @escaping @Sendable (Request) async throws -> HTTPHeaders? = { _ in [:] },
    onConnect: @escaping @Sendable (Request, any CodexAppServerMessageTransport) async -> Void
  ) -> Route {
    webSocket(
      on: routes,
      path: path,
      maxFrameSize: maxFrameSize,
      shouldUpgrade: shouldUpgrade,
      onConnect: onConnect
    )
  }

  @discardableResult
  public static func webSocket(
    on routes: RoutesBuilder,
    path: [PathComponent],
    maxFrameSize: WebSocketMaxFrameSize = .default,
    shouldUpgrade: @escaping @Sendable (Request) async throws -> HTTPHeaders? = { _ in [:] },
    onConnect: @escaping @Sendable (Request, any CodexAppServerMessageTransport) async -> Void
  ) -> Route {
    routes.webSocket(
      path,
      maxFrameSize: maxFrameSize,
      shouldUpgrade: shouldUpgrade
    ) { request, webSocket in
      let transport = CodexAppServerVaporWebSocketTransport(webSocket: webSocket)
      await onConnect(request, transport)
    }
  }
}

public final class CodexAppServerVaporWebSocketTransport: CodexAppServerMessageTransport,
  @unchecked Sendable
{
  public let inboundMessages: AsyncThrowingStream<String, Error>

  private let webSocket: any CodexAppServerVaporWebSocket
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  private let state: CodexAppServerVaporTransportState

  public convenience init(webSocket: WebSocket) {
    self.init(webSocket: webSocket as any CodexAppServerVaporWebSocket)
  }

  init(webSocket: any CodexAppServerVaporWebSocket) {
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let state = CodexAppServerVaporTransportState()

    self.webSocket = webSocket
    self.inboundChannel = inboundChannel
    self.state = state
    self.inboundMessages = inboundChannel.stream

    webSocket.setTextHandler { _, text in
      inboundChannel.yield(text)
    }
    webSocket.setBinaryHandler { webSocket, buffer in
      do {
        inboundChannel.yield(try Self.string(from: buffer))
      } catch {
        inboundChannel.finish(throwing: error)
        Task {
          await state.markClosed()
          await webSocket.closeSocket()
        }
      }
    }
    webSocket.onClose.whenComplete { _ in
      inboundChannel.finish()
      Task {
        await state.markClosed()
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

    await webSocket.closeSocket()
    inboundChannel.finish()
  }

  private static func string(from buffer: ByteBuffer) throws -> String {
    var data = buffer
    let bytes = data.readBytes(length: data.readableBytes) ?? []
    guard let message = String(data: Data(bytes), encoding: .utf8) else {
      throw CodexAppServerVaporError.invalidUTF8
    }
    return message
  }
}

protocol CodexAppServerVaporWebSocket: Sendable {
  var onClose: EventLoopFuture<Void> { get }

  func setTextHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, String) -> Void)
  func setBinaryHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, ByteBuffer) -> Void)
  func sendText(_ text: String) async throws
  func closeSocket() async
}

extension WebSocket: CodexAppServerVaporWebSocket {
  func setTextHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, String) -> Void
  ) {
    onText { webSocket, text in
      callback(webSocket, text)
    }
  }

  func setBinaryHandler(
    _ callback: @Sendable @escaping (CodexAppServerVaporWebSocket, ByteBuffer) -> Void
  ) {
    onBinary { webSocket, buffer in
      callback(webSocket, buffer)
    }
  }

  func sendText(_ text: String) async throws {
    try await send(text)
  }

  func closeSocket() async {
    try? await close(code: .normalClosure)
  }
}

private actor CodexAppServerVaporTransportState {
  private var isClosed = false

  func checkOpen() throws {
    if isClosed {
      throw CodexAppServerVaporError.closed
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
