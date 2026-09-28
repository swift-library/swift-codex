import CodexAppServerRuntime
import Foundation
import Testing

@testable import CodexAppServerClient

@Suite("App Server connection buffer ownership", .timeLimit(.minutes(1)))
struct CodexAppServerConnectionBufferTests {
  @Test("Full callback ownership rejects only excess requests and preserves client control")
  func callbackCapacityPreservesControl() async throws {
    typealias Wire = CodexAppServerConnectionFoundation
    let transport = BufferOverflowTransport()
    transport.releaseClose.continuation.finish()
    let connection = CodexAppServerConnection(transport: transport, inboundMessageMode: .rawOrdered)
    var incoming = connection.rawInboundMessages.makeAsyncIterator()
    var sent = transport.sent.stream.makeAsyncIterator()
    var callbacks: [CodexAppServerRawServerRequest] = []
    do {
      for id in 0..<256 {
        transport.receiving.continuation.yield(
          "{\"id\":\(id),\"method\":\"item/tool/call\",\"params\":{}}")
        guard case .serverRequest(let request) = try #require(try await incoming.next()) else {
          Issue.record("Expected an admitted server request")
          await connection.close()
          return
        }
        callbacks.append(request)
      }
      transport.receiving.continuation.yield(
        #"{"id":256,"method":"item/tool/call","params":{}}"#)
      let rejection = try Wire.decodeLine(try #require(await sent.next()))
      #expect(rejection.id == .integer(256))
      #expect(rejection.error?.code == -32_000)
      #expect(rejection.error?.message == "The pending server-request capacity is reached.")

      let control = Task { try await connection.sendRawRequest(method: "config/read") }
      let request = try Wire.decodeLine(try #require(await sent.next()))
      #expect(request.method == "config/read")
      transport.receiving.continuation.yield(
        try Wire.encodeLine(Wire.RawEnvelope(id: request.id, result: .bool(true))))
      #expect(try await control.value == .bool(true))

      // Releasing one callback permits a new token for that ID, not reuse of its old owner.
      let old = try #require(callbacks.first)
      try await connection.resolveServerRequest(old, with: true)
      let completion = try Wire.decodeLine(try #require(await sent.next()))
      #expect(completion.id == .integer(0))
      transport.receiving.continuation.yield(#"{"id":0,"method":"item/tool/call","params":{}}"#)
      guard case .serverRequest(let replacement) = try #require(try await incoming.next()) else {
        Issue.record("Expected the replacement callback")
        await connection.close()
        return
      }
      await #expect(throws: CodexAppServerClientError.serverRequestAlreadyCompleted(id: old.id)) {
        try await connection.resolveServerRequest(old, with: false)
      }
      try await connection.resolveServerRequest(replacement, with: true)
      _ = try #require(await sent.next())
      for callback in callbacks.dropFirst() {
        try await connection.resolveServerRequest(callback, with: true)
        _ = try #require(await sent.next())
      }
    } catch {
      await connection.close()
      throw error
    }
    await connection.close()
  }

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
