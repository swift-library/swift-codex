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

/// Limits count retained wire bytes, not the decoded Swift object's heap size.
package enum CodexAppServerBufferLimits {
  package static let messages = 256
  package static let bytes = 16 * 1_024 * 1_024
}

package final class CodexAppServerAsyncThrowingChannel<Element: Sendable>: Sendable {
  package let stream: AsyncThrowingStream<Element, Error>
  private let storage: Storage

  package init(
    maximumMessages: Int = CodexAppServerBufferLimits.messages,
    maximumBytes: Int = CodexAppServerBufferLimits.bytes
  ) {
    let storage = Storage(maximumMessages: maximumMessages, maximumBytes: maximumBytes)
    self.storage = storage
    self.stream = AsyncThrowingStream(unfolding: { try await storage.next() })
  }

  /// Admission never suspends the protocol reader behind a slow consumer.
  package func yield(_ element: Element, byteCount: Int) throws {
    try storage.yield(element, byteCount: byteCount)
  }

  package func finish() { storage.finish(.success(())) }
  package func finish(throwing error: Error) { storage.finish(.failure(error)) }

  private final class Storage: @unchecked Sendable {
    private struct Entry {
      let element: Element
      let byteCount: Int
    }
    private enum ConsumptionError: Error { case concurrentIteration }

    private let lock = NSLock()
    private let maximumMessages: Int
    private let maximumBytes: Int
    private var entries: [Entry?] = []
    private var head = 0
    private var byteCount = 0
    private var terminal: Result<Void, Error>?
    private var waiter: CheckedContinuation<Element?, Error>?

    init(maximumMessages: Int, maximumBytes: Int) {
      precondition(maximumMessages > 0 && maximumBytes > 0)
      self.maximumMessages = maximumMessages
      self.maximumBytes = maximumBytes
    }

    func yield(_ element: Element, byteCount: Int) throws {
      try lock.withLock {
        if let terminal = self.terminal {
          try terminal.get()
          throw CancellationError()
        }
        guard byteCount >= 0, byteCount <= maximumBytes,
          entries.count - head < maximumMessages,
          byteCount <= maximumBytes - self.byteCount
        else {
          let error = CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
            maximumMessages: maximumMessages, maximumBytes: maximumBytes)
          finishLocked(.failure(error))
          throw error
        }
        if let waiter = self.waiter {
          self.waiter = nil
          waiter.resume(returning: element)
        } else {
          entries.append(Entry(element: element, byteCount: byteCount))
          self.byteCount += byteCount
        }
      }
    }

    func next() async throws -> Element? {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          lock.withLock {
            if head < entries.count {
              let entry = entries[head]!
              entries[head] = nil
              head += 1
              byteCount -= entry.byteCount
              if head == entries.count {
                entries.removeAll(keepingCapacity: true)
                head = 0
              } else if head >= maximumMessages {
                entries.removeFirst(head)
                head = 0
              }
              continuation.resume(returning: entry.element)
            } else if let terminal = self.terminal {
              continuation.resume(with: terminal.map { nil })
            } else if waiter != nil {
              continuation.resume(throwing: ConsumptionError.concurrentIteration)
            } else {
              waiter = continuation
            }
          }
        }
      } onCancel: {
        self.finish(.failure(CancellationError()))
      }
    }

    func finish(_ result: Result<Void, Error>) {
      lock.withLock { finishLocked(result) }
    }

    private func finishLocked(_ result: Result<Void, Error>) {
      guard terminal == nil else { return }
      terminal = result
      // A failed connection cannot deliver an apparently valid suffix of its
      // backlog. Release retained payloads and expose the terminal cause now.
      if case .failure = result {
        entries.removeAll(keepingCapacity: false)
        head = 0
        byteCount = 0
      }
      if let waiter = self.waiter {
        self.waiter = nil
        waiter.resume(with: result.map { nil })
      }
    }
  }
}
