import CodexAppServerRuntime
import Foundation
import Testing

@Suite("CodexAppServerRuntime")
struct CodexAppServerRuntimeTests {
  @Test("stdio frame codec preserves newline-delimited JSON boundaries")
  func stdioFrameCodecPreservesNewlineDelimitedJSONBoundaries() throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec()

    #expect(try codec.appendIncoming(Data("{\"id\":1".utf8)).isEmpty)
    #expect(codec.hasPendingPartialLine)

    let lines = try codec.appendIncoming(Data("}\n{\"method\":\"initialized\"}\r\n".utf8))
    #expect(
      lines == [
        #"{"id":1}"#,
        #"{"method":"initialized"}"#,
      ])
    #expect(!codec.hasPendingPartialLine)
  }

  @Test("raw envelope classification separates requests, notifications, responses, and errors")
  func rawEnvelopeClassificationSeparatesMessageKinds() throws {
    #expect(
      try CodexAppServerConnectionFoundation.RawEnvelope(
        id: .integer(1),
        method: "thread/start"
      ).classify() == .request(id: .integer(1), method: "thread/start", params: nil))

    #expect(
      try CodexAppServerConnectionFoundation.RawEnvelope(
        method: "initialized"
      ).classify() == .notification(method: "initialized", params: nil))

    #expect(
      try CodexAppServerConnectionFoundation.RawEnvelope(
        id: .string("r1"),
        result: .bool(true)
      ).classify() == .success(id: .string("r1"), result: .bool(true)))

    #expect(
      try CodexAppServerConnectionFoundation.RawEnvelope(
        id: .integer(2),
        error: .init(code: -32600, message: "invalid")
      ).classify() == .failure(id: .integer(2), error: .init(code: -32600, message: "invalid")))
  }

  @Test("raw envelope classification rejects malformed message families")
  func rawEnvelopeClassificationRejectsMalformedMessageFamilies() throws {
    #expect(throws: CodexAppServerConnectionFoundation.FoundationError.invalidEnvelope) {
      _ = try CodexAppServerConnectionFoundation.RawEnvelope(
        jsonrpc: "1.0",
        id: .integer(1),
        method: "thread/start"
      ).classify()
    }

    #expect(throws: CodexAppServerConnectionFoundation.FoundationError.invalidEnvelope) {
      _ = try CodexAppServerConnectionFoundation.RawEnvelope(
        id: .integer(1),
        method: "thread/start",
        result: .null
      ).classify()
    }

    #expect(throws: CodexAppServerConnectionFoundation.FoundationError.invalidEnvelope) {
      _ = try CodexAppServerConnectionFoundation.RawEnvelope(
        result: .null
      ).classify()
    }
  }

  @Test("connection state correlates pending responses by runtime request id")
  func connectionStateCorrelatesPendingResponses() async throws {
    let state = CodexAppServerConnectionState()
    let requestID = try await state.allocateRequestID(nil)
    #expect(requestID == .integer(1))

    let pendingResponse = CodexAppServerPendingResponse()
    try await state.addPending(id: requestID, pendingResponse: pendingResponse)

    let waiter = Task {
      try await pendingResponse.wait()
    }

    let taken = await state.takePending(id: requestID)
    #expect(taken != nil)
    taken?.succeed(.object(["ok": .bool(true)]))

    let result = try await waiter.value
    #expect(result == .object(["ok": .bool(true)]))
  }

  @Test("message transport supports non-line adapters")
  func messageTransportSupportsNonLineAdapters() async throws {
    let transport = RuntimeMessageTransport()

    try await transport.sendMessage(#"{"method":"initialized"}"#)
    #expect(await transport.nextSentMessage() == #"{"method":"initialized"}"#)

    var iterator = transport.inboundMessages.makeAsyncIterator()
    transport.receiveMessage(#"{"id":1,"result":{}}"#)
    #expect(try await iterator.next() == #"{"id":1,"result":{}}"#)

    await transport.close()
    #expect(try await iterator.next() == nil)
  }

  @Test("line peers adapt to message transport")
  func linePeersAdaptToMessageTransport() async throws {
    let peer = RuntimeLinePeer()
    let transport: any CodexAppServerMessageTransport = peer

    try await transport.sendMessage(#"{"method":"initialized"}"#)
    #expect(await peer.nextSentLine() == #"{"method":"initialized"}"#)

    var iterator = transport.inboundMessages.makeAsyncIterator()
    peer.receiveLine(#"{"id":1,"result":{}}"#)
    #expect(try await iterator.next() == #"{"id":1,"result":{}}"#)

    await transport.close()
    #expect(try await iterator.next() == nil)
  }

  @Test("connection state cancellation records late responses as consumed")
  func connectionStateCancellationConsumesLateResponses() async throws {
    let state = CodexAppServerConnectionState()
    let requestID = CodexAppServerConnectionFoundation.RequestID.string("cancel-me")
    let pendingResponse = CodexAppServerPendingResponse()

    try await state.addPending(id: requestID, pendingResponse: pendingResponse)
    let waiter = Task {
      try await pendingResponse.wait()
    }

    await state.cancelPending(id: requestID, error: RuntimeTestError.cancelled)
    await #expect(throws: RuntimeTestError.cancelled) {
      _ = try await waiter.value
    }
    #expect(await state.consumeCancelledResponse(id: requestID))
    #expect(!(await state.consumeCancelledResponse(id: requestID)))
  }

  @Test("connection state tracks duplicate and completed server requests")
  func connectionStateTracksServerRequestLifecycle() async throws {
    let state = CodexAppServerConnectionState()
    let requestID = CodexAppServerConnectionFoundation.RequestID.integer(42)

    try await state.addServerRequest(id: requestID)
    await #expect(throws: CodexAppServerConnectionStateError.duplicateServerRequest(id: requestID))
    {
      try await state.addServerRequest(id: requestID)
    }

    try await state.completeServerRequest(id: requestID)
    await #expect(
      throws: CodexAppServerConnectionStateError.serverRequestAlreadyCompleted(id: requestID)
    ) {
      try await state.completeServerRequest(id: requestID)
    }
  }

  @Test("connection state rejects duplicate pending response ids")
  func connectionStateRejectsDuplicatePendingResponseIDs() async throws {
    let state = CodexAppServerConnectionState()
    let requestID = CodexAppServerConnectionFoundation.RequestID.integer(7)

    try await state.addPending(id: requestID, pendingResponse: .init())
    await #expect(
      throws: CodexAppServerConnectionStateError.duplicatePendingResponse(id: requestID)
    ) {
      try await state.addPending(id: requestID, pendingResponse: .init())
    }
  }

  @Test("connection close fails pending responses and rejects new request ids")
  func connectionCloseFailsPendingResponsesAndRejectsNewRequestIDs() async throws {
    let state = CodexAppServerConnectionState()
    let requestID = try await state.allocateRequestID(nil)
    let pendingResponse = CodexAppServerPendingResponse()
    try await state.addPending(id: requestID, pendingResponse: pendingResponse)

    let waiter = Task {
      try await pendingResponse.wait()
    }
    let pending = await state.close(error: RuntimeTestError.closed)
    #expect(pending.count == 1)
    pending.first?.fail(RuntimeTestError.closed)

    await #expect(throws: RuntimeTestError.closed) {
      _ = try await waiter.value
    }
    await #expect(throws: CodexAppServerConnectionStateError.closed) {
      _ = try await state.allocateRequestID(nil)
    }
  }
}

private enum RuntimeTestError: Error, Equatable {
  case cancelled
  case closed
}

private final class RuntimeMessageTransport: CodexAppServerMessageTransport, @unchecked Sendable {
  let inboundMessages: AsyncThrowingStream<String, Error>

  private let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
  private let sentMessages = RuntimeMessageMailbox()

  init() {
    inboundMessages = inboundChannel.stream
  }

  func sendMessage(_ message: String) async throws {
    await sentMessages.append(message)
  }

  func close() async {
    inboundChannel.finish()
  }

  func receiveMessage(_ message: String) {
    inboundChannel.yield(message)
  }

  func nextSentMessage() async -> String {
    await sentMessages.next()
  }
}

private final class RuntimeLinePeer: CodexAppServerLinePeer, @unchecked Sendable {
  let inboundLines: AsyncThrowingStream<String, Error>

  private let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
  private let sentLines = RuntimeMessageMailbox()

  init() {
    inboundLines = inboundChannel.stream
  }

  func sendLine(_ line: String) async throws {
    await sentLines.append(line)
  }

  func close() async {
    inboundChannel.finish()
  }

  func receiveLine(_ line: String) {
    inboundChannel.yield(line)
  }

  func nextSentLine() async -> String {
    await sentLines.next()
  }
}

private actor RuntimeMessageMailbox {
  private var messages: [String] = []
  private var waiters: [CheckedContinuation<String, Never>] = []

  func append(_ message: String) {
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume(returning: message)
      return
    }

    messages.append(message)
  }

  func next() async -> String {
    if !messages.isEmpty {
      return messages.removeFirst()
    }

    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
