import CodexAppServerRuntime
import Foundation
import Testing

@testable import CodexAppServerClient

@Suite("App Server connection buffer ownership", .timeLimit(.minutes(1)))
struct CodexAppServerConnectionBufferTests {
  @Test("Original wire bytes bound decoded raw notification backlog")
  func rawByteBudget() async throws {
    let transport = BufferOverflowTransport()
    let connection = CodexAppServerConnection(transport: transport, inboundMessageMode: .rawOrdered)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    var sent = transport.sent.stream.makeAsyncIterator()
    _ = await sent.next()
    let message =
      "{\"method\":\"warning\",\"params\":{\"message\":\""
      + String(repeating: "x", count: 8 * 1_024 * 1_024) + "\"}}"
    transport.receiving.continuation.yield(message)
    transport.receiving.continuation.yield(message)
    await #expect(
      throws: CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
        maximumMessages: CodexAppServerBufferLimits.messages,
        maximumBytes: CodexAppServerBufferLimits.bytes)
    ) { try await pending.value }
    transport.releaseClose.continuation.finish()
    await connection.close()
  }

  @Test(
    "An unconsumed notification stream fails replies before native cleanup completes",
    arguments: [CodexAppServerClient.InboundMessageMode.typed, .raw, .rawOrdered])
  func overflowClosesConnection(mode: CodexAppServerClient.InboundMessageMode) async throws {
    let transport = BufferOverflowTransport()
    let connection = CodexAppServerConnection(transport: transport, inboundMessageMode: mode)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    var sent = transport.sent.stream.makeAsyncIterator()
    _ = await sent.next()
    for _ in 0...CodexAppServerBufferLimits.messages {
      transport.receiving.continuation.yield(
        #"{"method":"warning","params":{"message":"fixture","threadId":null}}"#)
    }
    let failure = CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
      maximumMessages: CodexAppServerBufferLimits.messages,
      maximumBytes: CodexAppServerBufferLimits.bytes)
    await #expect(throws: failure) { try await pending.value }
    var closing = transport.closeEntered.stream.makeAsyncIterator()
    _ = await closing.next()
    do {
      switch mode {
      case .typed:
        var iterator = connection.notifications.makeAsyncIterator()
        await #expect(throws: failure) { try await iterator.next() }
      case .raw:
        var iterator = connection.rawNotifications.makeAsyncIterator()
        await #expect(throws: failure) { try await iterator.next() }
      case .rawOrdered:
        var iterator = connection.rawInboundMessages.makeAsyncIterator()
        await #expect(throws: failure) { try await iterator.next() }
      }
      await #expect(throws: CodexAppServerClientError.closed) {
        try await connection.sendRawRequest(method: "config/read")
      }
    }
    transport.releaseClose.continuation.finish()
    await connection.close()
  }
}

private final class BufferOverflowTransport: CodexAppServerMessageTransport {
  let receiving = AsyncThrowingStream<String, Error>.makeStream()
  let sent = AsyncStream<String>.makeStream()
  let closeEntered = AsyncStream<Void>.makeStream()
  let releaseClose = AsyncStream<Void>.makeStream()
  var inboundMessages: AsyncThrowingStream<String, Error> { receiving.stream }

  func sendMessage(_ message: String) async throws { sent.continuation.yield(message) }
  func close() async {
    receiving.continuation.finish()
    closeEntered.continuation.yield(())
    var release = releaseClose.stream.makeAsyncIterator()
    _ = await release.next()
  }
}
