import CodexAppServerRuntime
import CodexAppServerTestingSupport
import Testing

@testable import CodexAppServerClient

@Suite("CodexAppServer connection close", .timeLimit(.minutes(1)))
struct CodexAppServerConnectionCloseTests {
  @Test(
    "Local close finishes streams while transport cleanup is suspended",
    arguments: [
      CodexAppServerClient.InboundMessageMode.typed, .raw, .rawOrdered,
    ])
  func localCloseOwnsTerminalState(mode: CodexAppServerClient.InboundMessageMode) async throws {
    let transport = SuspendedCloseTransport()
    let connection = CodexAppServerConnection(transport: transport, inboundMessageMode: mode)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    _ = await transport.peer.nextSentLine()
    let closing = Task { await connection.close() }
    var entered = transport.closeEntered.stream.makeAsyncIterator()
    _ = await entered.next()

    var streamFailure: (any Error)?
    do {
      switch mode {
      case .typed:
        var messages = connection.notifications.makeAsyncIterator()
        #expect(try await messages.next() == nil)
      case .raw:
        var messages = connection.rawNotifications.makeAsyncIterator()
        #expect(try await messages.next() == nil)
      case .rawOrdered:
        var messages = connection.rawInboundMessages.makeAsyncIterator()
        #expect(try await messages.next() == nil)
      }
    } catch {
      streamFailure = error
    }
    transport.releaseClose.continuation.yield(())
    await closing.value
    #expect(streamFailure == nil)
    await #expect(throws: CodexAppServerClientError.closed) { try await pending.value }
  }

  @Test("Peer EOF preserves its failure through subsequent local cleanup")
  func peerCloseOwnsTerminalState() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .rawOrdered)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    _ = await peer.nextSentLine()
    peer.finishInbound()
    await #expect(throws: CodexAppServerClientError.peerClosed) { try await pending.value }
    await connection.close()
    var messages = connection.rawInboundMessages.makeAsyncIterator()
    await #expect(throws: CodexAppServerClientError.peerClosed) { try await messages.next() }
  }
}

private final class SuspendedCloseTransport: CodexAppServerMessageTransport {
  let peer = CodexAppServerInMemoryLinePeer()
  let closeEntered = AsyncStream<Void>.makeStream()
  let releaseClose = AsyncStream<Void>.makeStream()

  var inboundMessages: AsyncThrowingStream<String, Error> { peer.inboundMessages }

  func sendMessage(_ message: String) async throws { try await peer.sendMessage(message) }

  func close() async {
    peer.finishInbound()
    closeEntered.continuation.yield(())
    var release = releaseClose.stream.makeAsyncIterator()
    _ = await release.next()
  }
}
