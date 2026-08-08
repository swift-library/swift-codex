import Foundation
import Testing

@testable import CodexAppServerURLSession

@Suite("CodexAppServerURLSession Transport")
struct CodexAppServerURLSessionTransportTests {
  @Test("transport resumes websocket and emits inbound text messages")
  func transportResumesWebSocketAndEmitsInboundTextMessages() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)

    await task.waitUntilResumed()

    var iterator = transport.inboundMessages.makeAsyncIterator()
    await task.enqueueInbound(.string(#"{"method":"initialized"}"#))

    #expect(try await iterator.next() == #"{"method":"initialized"}"#)

    await transport.close()
  }

  @Test("transport decodes inbound binary utf8 messages")
  func transportDecodesInboundBinaryUTF8Messages() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)
    var iterator = transport.inboundMessages.makeAsyncIterator()

    await task.enqueueInbound(.data(Data(#"{"id":1,"result":{}}"#.utf8)))

    #expect(try await iterator.next() == #"{"id":1,"result":{}}"#)

    await transport.close()
  }

  @Test("transport sends outbound text messages")
  func transportSendsOutboundTextMessages() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)

    try await transport.sendMessage(#"{"method":"initialized"}"#)

    #expect(await task.nextSentString() == #"{"method":"initialized"}"#)

    await transport.close()
  }

  @Test("transport close cancels websocket and finishes inbound stream")
  func transportCloseCancelsWebSocketAndFinishesInboundStream() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)
    var iterator = transport.inboundMessages.makeAsyncIterator()

    await transport.close()

    #expect(await task.waitUntilCancelled() == .normalClosure)
    #expect(try await iterator.next() == nil)
    await #expect(throws: CodexAppServerURLSessionError.closed) {
      try await transport.sendMessage(#"{"method":"initialized"}"#)
    }
  }

  @Test("transport propagates receive failure through inbound stream")
  func transportPropagatesReceiveFailureThroughInboundStream() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)
    var iterator = transport.inboundMessages.makeAsyncIterator()

    await task.failInbound(FakeWebSocketError.disconnected)

    await #expect(throws: FakeWebSocketError.disconnected) {
      _ = try await iterator.next()
    }
    await #expect(throws: CodexAppServerURLSessionError.closed) {
      try await transport.sendMessage(#"{"method":"initialized"}"#)
    }

    await transport.close()
  }

  @Test("transport rejects invalid utf8 binary messages")
  func transportRejectsInvalidUTF8BinaryMessages() async throws {
    let task = FakeWebSocketTask()
    let transport = CodexAppServerURLSessionTransport(webSocketTask: task)
    var iterator = transport.inboundMessages.makeAsyncIterator()

    await task.enqueueInbound(.data(Data([0xFF])))

    await #expect(throws: CodexAppServerURLSessionError.invalidUTF8) {
      _ = try await iterator.next()
    }

    await transport.close()
  }
}

private enum FakeWebSocketError: Error, Equatable {
  case disconnected
}

private final class FakeWebSocketTask: CodexAppServerURLSessionWebSocketTask, @unchecked Sendable {
  private let state = FakeWebSocketTaskState()

  func resume() {
    Task {
      await state.resume()
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    try await state.send(message)
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    try await state.receive()
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    Task {
      await state.cancel(closeCode: closeCode)
    }
  }

  func enqueueInbound(_ message: URLSessionWebSocketTask.Message) async {
    await state.enqueueInbound(message)
  }

  func failInbound(_ error: Error) async {
    await state.failInbound(error)
  }

  func nextSentString() async -> String? {
    await state.nextSentString()
  }

  func waitUntilResumed() async {
    await state.waitUntilResumed()
  }

  func waitUntilCancelled() async -> URLSessionWebSocketTask.CloseCode {
    await state.waitUntilCancelled()
  }
}

private actor FakeWebSocketTaskState {
  private(set) var didResume = false
  private(set) var cancelledCloseCode: URLSessionWebSocketTask.CloseCode?
  private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelWaiters: [CheckedContinuation<URLSessionWebSocketTask.CloseCode, Never>] = []
  private var sentMessages: [URLSessionWebSocketTask.Message] = []
  private var sentWaiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Never>] = []
  private var inboundResults: [Result<URLSessionWebSocketTask.Message, Error>] = []
  private var inboundWaiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []

  func resume() {
    didResume = true
    while !resumeWaiters.isEmpty {
      resumeWaiters.removeFirst().resume()
    }
  }

  func waitUntilResumed() async {
    if didResume {
      return
    }

    await withCheckedContinuation { continuation in
      resumeWaiters.append(continuation)
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message) throws {
    if cancelledCloseCode != nil {
      throw CodexAppServerURLSessionError.closed
    }

    if !sentWaiters.isEmpty {
      sentWaiters.removeFirst().resume(returning: message)
      return
    }

    sentMessages.append(message)
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    if !inboundResults.isEmpty {
      return try inboundResults.removeFirst().get()
    }

    return try await withCheckedThrowingContinuation { continuation in
      inboundWaiters.append(continuation)
    }
  }

  func cancel(closeCode: URLSessionWebSocketTask.CloseCode) {
    guard cancelledCloseCode == nil else {
      return
    }

    cancelledCloseCode = closeCode
    while !cancelWaiters.isEmpty {
      cancelWaiters.removeFirst().resume(returning: closeCode)
    }
    while !inboundWaiters.isEmpty {
      inboundWaiters.removeFirst().resume(throwing: CancellationError())
    }
  }

  func waitUntilCancelled() async -> URLSessionWebSocketTask.CloseCode {
    if let cancelledCloseCode {
      return cancelledCloseCode
    }

    return await withCheckedContinuation { continuation in
      cancelWaiters.append(continuation)
    }
  }

  func enqueueInbound(_ message: URLSessionWebSocketTask.Message) {
    if !inboundWaiters.isEmpty {
      inboundWaiters.removeFirst().resume(returning: message)
      return
    }

    inboundResults.append(.success(message))
  }

  func failInbound(_ error: Error) {
    if !inboundWaiters.isEmpty {
      inboundWaiters.removeFirst().resume(throwing: error)
      return
    }

    inboundResults.append(.failure(error))
  }

  func nextSentString() async -> String? {
    let message: URLSessionWebSocketTask.Message
    if !sentMessages.isEmpty {
      message = sentMessages.removeFirst()
    } else {
      message = await withCheckedContinuation { continuation in
        sentWaiters.append(continuation)
      }
    }

    if case .string(let value) = message {
      return value
    }
    return nil
  }
}
