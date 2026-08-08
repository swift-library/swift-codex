import Foundation

public protocol CodexAppServerMessageTransport: Sendable {
  var inboundMessages: AsyncThrowingStream<String, Error> { get }

  func sendMessage(_ message: String) async throws
  func close() async
}

public protocol CodexAppServerLinePeer: CodexAppServerMessageTransport {
  var inboundLines: AsyncThrowingStream<String, Error> { get }

  func sendLine(_ line: String) async throws
}

extension CodexAppServerLinePeer {
  public var inboundMessages: AsyncThrowingStream<String, Error> {
    inboundLines
  }

  public func sendMessage(_ message: String) async throws {
    try await sendLine(message)
  }
}

package final class CodexAppServerAsyncThrowingChannel<Element: Sendable>: @unchecked Sendable {
  package let stream: AsyncThrowingStream<Element, Error>

  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Element, Error>.Continuation?

  package init() {
    var capturedContinuation: AsyncThrowingStream<Element, Error>.Continuation?
    self.stream = AsyncThrowingStream<Element, Error> { continuation in
      capturedContinuation = continuation
    }
    self.continuation = capturedContinuation
  }

  package func yield(_ element: Element) {
    lock.lock()
    let continuation = self.continuation
    lock.unlock()

    continuation?.yield(element)
  }

  package func finish() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()

    continuation?.finish()
  }

  package func finish(throwing error: Error) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()

    continuation?.finish(throwing: error)
  }
}
