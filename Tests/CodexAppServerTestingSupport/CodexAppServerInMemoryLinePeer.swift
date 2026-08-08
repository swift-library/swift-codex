import CodexAppServerRuntime
import Foundation

public final class CodexAppServerInMemoryLinePeer: CodexAppServerLinePeer, @unchecked Sendable {
  public let inboundLines: AsyncThrowingStream<String, Error>

  private let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
  private let sentLines = CodexAppServerSentLineMailbox()

  public init() {
    self.inboundLines = inboundChannel.stream
  }

  public func sendLine(_ line: String) async throws {
    await sentLines.append(line)
  }

  public func close() async {
    inboundChannel.finish()
  }

  public func receiveLine(_ line: String) {
    inboundChannel.yield(line)
  }

  public func finishInbound() {
    inboundChannel.finish()
  }

  public func nextSentLine() async -> String {
    await sentLines.next()
  }
}

private actor CodexAppServerSentLineMailbox {
  private var lines: [String] = []
  private var waiters: [CheckedContinuation<String, Never>] = []

  func append(_ line: String) {
    if waiters.isEmpty {
      lines.append(line)
      return
    }

    let waiter = waiters.removeFirst()
    waiter.resume(returning: line)
  }

  func next() async -> String {
    if !lines.isEmpty {
      return lines.removeFirst()
    }

    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
