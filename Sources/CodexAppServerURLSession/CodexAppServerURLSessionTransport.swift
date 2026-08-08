import CodexAppServerRuntime
import Foundation

public enum CodexAppServerURLSessionError: Error, Equatable, Sendable {
  case closed
  case invalidUTF8
  case unsupportedMessage
}

public final class CodexAppServerURLSessionTransport: CodexAppServerMessageTransport,
  @unchecked Sendable
{
  public let inboundMessages: AsyncThrowingStream<String, Error>

  private let webSocketTask: any CodexAppServerURLSessionWebSocketTask
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  private let state: CodexAppServerURLSessionTransportState
  private let receiveTask: Task<Void, Never>

  public convenience init(
    url: URL,
    session: URLSession = .shared,
    protocols: [String] = []
  ) {
    self.init(
      webSocketTask: CodexAppServerURLSessionWebSocketTaskAdapter(
        session.webSocketTask(with: url, protocols: protocols)
      ))
  }

  init(webSocketTask: any CodexAppServerURLSessionWebSocketTask) {
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let state = CodexAppServerURLSessionTransportState()

    self.webSocketTask = webSocketTask
    self.inboundChannel = inboundChannel
    self.inboundMessages = inboundChannel.stream
    self.state = state
    self.receiveTask = Task { [webSocketTask, inboundChannel, state] in
      do {
        try await Self.receiveMessages(
          from: webSocketTask,
          into: inboundChannel
        )
        await state.markClosed()
        inboundChannel.finish()
      } catch is CancellationError {
        await state.markClosed()
        inboundChannel.finish()
      } catch {
        await state.markClosed()
        inboundChannel.finish(throwing: error)
      }
    }

    webSocketTask.resume()
  }

  public func sendMessage(_ message: String) async throws {
    try await state.checkOpen()
    try await webSocketTask.send(.string(message))
  }

  public func close() async {
    guard await state.close() else {
      return
    }

    receiveTask.cancel()
    webSocketTask.cancel(with: .normalClosure, reason: nil)
    inboundChannel.finish()
  }

  private static func receiveMessages(
    from webSocketTask: any CodexAppServerURLSessionWebSocketTask,
    into inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  ) async throws {
    while !Task.isCancelled {
      switch try await webSocketTask.receive() {
      case .string(let message):
        inboundChannel.yield(message)
      case .data(let data):
        guard let message = String(data: data, encoding: .utf8) else {
          throw CodexAppServerURLSessionError.invalidUTF8
        }
        inboundChannel.yield(message)
      @unknown default:
        throw CodexAppServerURLSessionError.unsupportedMessage
      }
    }
  }
}

protocol CodexAppServerURLSessionWebSocketTask: AnyObject, Sendable {
  func resume()
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

private final class CodexAppServerURLSessionWebSocketTaskAdapter:
  CodexAppServerURLSessionWebSocketTask,
  @unchecked Sendable
{
  private let task: URLSessionWebSocketTask

  init(_ task: URLSessionWebSocketTask) {
    self.task = task
  }

  func resume() {
    task.resume()
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    try await task.send(message)
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    try await task.receive()
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    task.cancel(with: closeCode, reason: reason)
  }
}

private actor CodexAppServerURLSessionTransportState {
  private var isClosed = false

  func checkOpen() throws {
    if isClosed {
      throw CodexAppServerURLSessionError.closed
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
