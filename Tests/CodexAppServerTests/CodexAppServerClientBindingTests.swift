import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable
private typealias Experimental = CodexAppServerProtocol.Experimental

@Suite("CodexAppServer Client Binding")
struct CodexAppServerClientBindingTests {
  @Test("Unknown notifications are observed without closing the typed connection")
  func unknownNotificationsAreObservedWithoutClosingConnection() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var observations = connection.unhandledInboundMessages.makeAsyncIterator()
    var notifications = connection.notifications.makeAsyncIterator()
    let method = String(repeating: "future/", count: 50)
    let line = try CodexAppServerConnectionFoundation.encodeLine(
      CodexAppServerConnectionFoundation.RawEnvelope(
        jsonrpc: "2.0",
        method: method,
        params: .object(["secret": .string("must-not-be-retained")])
      )
    )

    peer.receiveLine(line)

    let observation = try #require(try await observations.next())
    #expect(observation.kind == .notification)
    #expect(observation.methodStatus == .unknown)
    #expect(observation.methodWasTruncated)
    #expect(observation.method.count == 256)
    #expect(observation.parameters.shape == .object)
    #expect(observation.parameters.valueCount == 1)
    #expect(observation.messageByteCount == line.utf8.count)

    peer.receiveLine(try warningNotificationLine("connection remains usable"))
    guard case .warningnotification(let warning) = try await notifications.next() else {
      Issue.record("Expected the known notification after the unknown notification.")
      await connection.close()
      return
    }
    #expect(warning.params.message == "connection remains usable")
    await connection.close()
  }

  @Test("Unhandled server requests are rejected and observed without closing the connection")
  func unhandledServerRequestsAreRejectedAndObserved() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var observations = connection.unhandledInboundMessages.makeAsyncIterator()
    var notifications = connection.notifications.makeAsyncIterator()
    let requestID = CodexAppServerConnectionFoundation.RequestID.string("future-request")

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        CodexAppServerConnectionFoundation.RawEnvelope(
          jsonrpc: "2.0",
          id: requestID,
          method: "future/request",
          params: .object(["secret": .string("must-not-be-retained")])
        )
      )
    )

    let rejection = try CodexAppServerConnectionFoundation.decodeLine(await peer.nextSentLine())
    guard case .failure(let rejectedID, let error) = try rejection.classify() else {
      Issue.record("Expected a JSON-RPC rejection for the unhandled request.")
      await connection.close()
      return
    }
    #expect(rejectedID == requestID)
    #expect(error.code == -32_601)
    #expect(error.message == "Method not found")
    #expect(error.data == nil)

    let observation = try #require(try await observations.next())
    #expect(observation.kind == .rejectedRequest)
    #expect(observation.methodStatus == .unknown)
    #expect(observation.method == "future/request")
    #expect(observation.parameters.shape == .object)
    #expect(observation.parameters.valueCount == 1)

    peer.receiveLine(try warningNotificationLine("connection remains usable"))
    guard case .warningnotification = try await notifications.next() else {
      Issue.record("Expected the typed connection to remain usable after rejection.")
      await connection.close()
      return
    }
    await connection.close()
  }

  @Test("Experimental current-time requests use a typed response handle")
  func currentTimeRequestsUseTypedResponseHandle() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        Experimental.ServerRequest.currenttimeReadRequest(
          .init(
            id: .requestidoption1("current-time"),
            method: .currenttimeRead,
            params: .init(threadId: "thread-1")
          )
        )
      )
    )

    guard case .currentTimeRead(let request) = try await requests.next() else {
      Issue.record("Expected a typed current-time request.")
      await connection.close()
      return
    }
    #expect(request.id == .requestidoption1("current-time"))
    #expect(request.params.threadId == "thread-1")

    try await connection.resolveServerRequest(
      request,
      with: Experimental.CurrentTimeReadResponse(currentTimeAt: 1_725_000_000)
    )
    let response = try CodexAppServerConnectionFoundation.decodeLine(await peer.nextSentLine())
    guard case .success(let id, let result) = try response.classify() else {
      Issue.record("Expected a current-time JSON-RPC response.")
      await connection.close()
      return
    }
    #expect(id == .string("current-time"))
    #expect(
      result == .object(["currentTimeAt": .number(.integer(1_725_000_000))])
    )
    await connection.close()
  }

  @Test("Malformed experimental current-time parameters fail closed")
  func malformedCurrentTimeParametersFailClosed() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        CodexAppServerConnectionFoundation.RawEnvelope(
          jsonrpc: "2.0",
          id: .string("bad-current-time"),
          method: "currentTime/read",
          params: .object([:])
        )
      )
    )

    do {
      _ = try await requests.next()
      Issue.record("Expected malformed current-time parameters to fail closed.")
    } catch let error as CodexAppServerClientError {
      guard case .malformedInbound(let diagnostic) = error else {
        Issue.record("Expected malformedInbound, got \(error).")
        await connection.close()
        return
      }
      #expect(diagnostic.contains("server request 'currentTime/read' decode failed"))
    }
    await connection.close()
  }

  @Test("Malformed parameters for a known method still fail closed")
  func malformedKnownMethodParametersStillFailClosed() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var notifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        CodexAppServerConnectionFoundation.RawEnvelope(
          jsonrpc: "2.0",
          method: "warning",
          params: .object([:])
        )
      )
    )

    do {
      _ = try await notifications.next()
      Issue.record("Expected malformed known notification parameters to fail closed.")
    } catch let error as CodexAppServerClientError {
      guard case .malformedInbound(let diagnostic) = error else {
        Issue.record("Expected malformedInbound, got \(error).")
        await connection.close()
        return
      }
      #expect(diagnostic.contains("notification 'warning' decode failed"))
    }
    await connection.close()
  }

  @Test("Typed callbacks reject foreign and stale owners even when request IDs match")
  func typedCallbackOwnershipSurvivesIDReuse() async throws {
    let firstPeer = CodexAppServerInMemoryLinePeer()
    let secondPeer = CodexAppServerInMemoryLinePeer()
    let first = try await startReadyConnection(peer: firstPeer)
    let second = try await startReadyConnection(peer: secondPeer)
    var firstRequests = first.typedServerRequests.makeAsyncIterator()
    var secondRequests = second.typedServerRequests.makeAsyncIterator()
    let id = Stable.RequestId.requestidoption1("shared-id")
    let line = try CodexAppServerConnectionFoundation.encodeLine(authRefreshServerRequest(id: id))
    firstPeer.receiveLine(line)
    secondPeer.receiveLine(line)
    guard case .chatgptAuthTokensRefresh(let original) = try await firstRequests.next(),
      case .chatgptAuthTokensRefresh(let other) = try await secondRequests.next()
    else {
      Issue.record("Expected both typed callbacks")
      await first.close()
      await second.close()
      return
    }
    await #expect(throws: CodexAppServerClientError.foreignServerRequest(id: id)) {
      try await second.rejectServerRequest(original, code: -32603, message: "foreign")
    }
    try await first.rejectServerRequest(original, code: -32603, message: "first")
    _ = await firstPeer.nextSentLine()
    firstPeer.receiveLine(line)
    guard case .chatgptAuthTokensRefresh(let replacement) = try await firstRequests.next() else {
      Issue.record("Expected replacement typed callback")
      await first.close()
      await second.close()
      return
    }
    await #expect(throws: CodexAppServerClientError.serverRequestAlreadyCompleted(id: id)) {
      try await first.rejectServerRequest(original, code: -32603, message: "stale")
    }
    try await first.rejectServerRequest(replacement, code: -32603, message: "replacement")
    _ = await firstPeer.nextSentLine()
    try await second.rejectServerRequest(other, code: -32603, message: "second")
    _ = await secondPeer.nextSentLine()
    await first.close()
    await second.close()
  }

  @Test("Unknown-method observations retain only the latest 64 entries")
  func unhandledObservationsHaveBoundedBacklog() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var notifications = connection.notifications.makeAsyncIterator()
    for index in 0..<100 {
      peer.receiveLine("{\"method\":\"future/\(index)\",\"params\":null}")
    }
    peer.receiveLine(try warningNotificationLine("drained"))
    _ = try #require(try await notifications.next())
    await connection.close()
    var methods: [String] = []
    for try await observation in connection.unhandledInboundMessages {
      methods.append(observation.method)
    }
    #expect(methods == (36..<100).map { "future/\($0)" })
  }

  @Test("Observation method limits count UTF-8 bytes and preserve valid Unicode")
  func observationMethodHasByteLimit() {
    let method = String(repeating: "🐈", count: 63) + "a🐈"
    let observation = CodexAppServerUnhandledInboundMessage(
      kind: .notification, methodStatus: .unknown, method: method,
      params: .string("sensitive-value"), messageByteCount: 300)
    #expect(observation.method == String(repeating: "🐈", count: 63) + "a")
    #expect(observation.method.utf8.count == 253)
    #expect(observation.methodWasTruncated)
    #expect(observation.parameters.valueCount == 15)
  }

  @Test("Client binding performs initialize / initialized handshake through fake peer")
  func clientBindingPerformsInitializeHandshakeThroughFakePeer() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let startTask = Task {
      try await makeClient(peer: peer).start()
    }

    let initializeLine = await peer.nextSentLine()
    let initializeRequest = try CodexAppServerProtocolContractSupport.Initialize
      .decodeInitializeRequest(from: initializeLine)
    #expect(initializeRequest.method == .initialize)
    #expect(initializeRequest.params.clientInfo.name == "swift_codex_tests")
    #expect(initializeRequest.params.clientInfo.title == "swift-codex Tests")
    #expect(initializeRequest.params.clientInfo.version == "0.1.0")
    #expect(initializeRequest.params.capabilities?.experimentalApi == false)
    #expect(initializeRequest.params.capabilities?.optOutNotificationMethods == ["warning"])

    peer.receiveLine(try initializeResponseLine(id: initializeRequest.id))

    let initializedLine = await peer.nextSentLine()
    let initialized = try CodexAppServerProtocolContractSupport.Initialize
      .decodeInitializedNotification(from: initializedLine)
    #expect(initialized.method == .initialized)

    let connection = try await startTask.value
    await connection.close()
  }

  @Test("Client binding correlates one typed generated response by request id")
  func clientBindingCorrelatesTypedGeneratedResponseByRequestID() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: true, limit: 1),
        responseType: Stable.ModelListResponse.self
      )
    }

    let requestLine = await peer.nextSentLine()
    let clientRequest = try decode(Stable.ClientRequest.self, from: requestLine)
    guard case .modelListRequest(let modelListRequest) = clientRequest else {
      Issue.record("Expected model/list generated request.")
      return
    }
    #expect(modelListRequest.params.includeHidden == true)

    peer.receiveLine(
      try responseLine(
        id: modelListRequest.id,
        result: Stable.ModelListResponse(data: [], nextCursor: "done")
      ))

    let response = try await requestTask.value
    #expect(response.nextCursor == "done")
    #expect(response.data.isEmpty)

    await connection.close()
  }

  @Test("Client binding preserves large integers before typed response decoding")
  func clientBindingPreservesLargeIntegersBeforeTypedResponseDecoding() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    let expectedValue: Int64 = 9_007_199_254_740_993

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "test/largeInteger",
        responseType: LargeIntegerResponse.self
      )
    }

    let requestLine = await peer.nextSentLine()
    let requestEnvelope = try CodexAppServerConnectionFoundation.decodeLine(requestLine)
    guard case .request(let id, let method, _) = try requestEnvelope.classify() else {
      Issue.record("Expected raw request envelope.")
      return
    }
    #expect(method == "test/largeInteger")

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        CodexAppServerConnectionFoundation.RawEnvelope(
          jsonrpc: "2.0",
          id: id,
          result: .object(["value": .number(.integer(expectedValue))])
        )
      ))

    #expect(try await requestTask.value.value == expectedValue)

    await connection.close()
  }

  @Test("Client binding correlates concurrent typed responses by id, not arrival order")
  func clientBindingCorrelatesConcurrentResponsesByID() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let firstTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: "first", includeHidden: nil, limit: 1),
        responseType: Stable.ModelListResponse.self
      )
    }
    let secondTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: "second", includeHidden: nil, limit: 1),
        responseType: Stable.ModelListResponse.self
      )
    }

    let firstOutboundLine = await peer.nextSentLine()
    let secondOutboundLine = await peer.nextSentLine()
    let requestIDsByCursor = try modelListRequestIDsByCursor([
      firstOutboundLine,
      secondOutboundLine,
    ])
    guard
      let firstRequestID = requestIDsByCursor["first"],
      let secondRequestID = requestIDsByCursor["second"]
    else {
      Issue.record("Expected both first and second model/list requests.")
      return
    }

    peer.receiveLine(
      try responseLine(
        id: secondRequestID,
        result: Stable.ModelListResponse(data: [], nextCursor: "second-result")
      ))
    peer.receiveLine(
      try responseLine(
        id: firstRequestID,
        result: Stable.ModelListResponse(data: [], nextCursor: "first-result")
      ))

    #expect(try await firstTask.value.nextCursor == "first-result")
    #expect(try await secondTask.value.nextCursor == "second-result")

    await connection.close()
  }

  @Test("Client binding delivers ordered generated server notifications")
  func clientBindingDeliversOrderedGeneratedServerNotifications() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var iterator = connection.notifications.makeAsyncIterator()

    peer.receiveLine(try warningNotificationLine("first"))
    peer.receiveLine(try warningNotificationLine("second"))

    let first = try await iterator.next()
    let second = try await iterator.next()

    #expect(warningMessage(first) == "first")
    #expect(warningMessage(second) == "second")

    await connection.close()
  }

  @Test("Client binding observes and resolves generated server request")
  func clientBindingObservesAndResolvesGeneratedServerRequest() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var iterator = connection.typedServerRequests.makeAsyncIterator()
    let request = authRefreshServerRequest(id: .requestidoption1("auth-1"))

    peer.receiveLine(try CodexAppServerConnectionFoundation.encodeLine(request))

    guard case .chatgptAuthTokensRefresh(let serverRequest) = try await iterator.next() else {
      Issue.record("Expected typed auth refresh request.")
      return
    }
    #expect(serverRequest.id == .requestidoption1("auth-1"))

    try await connection.resolveServerRequest(
      serverRequest,
      with: Stable.ChatgptAuthTokensRefreshResponse(
        accessToken: "access-token",
        chatgptAccountId: "account-id",
        chatgptPlanType: nil
      )
    )

    let outboundLine = await peer.nextSentLine()
    let response = try decode(Stable.JSONRPCResponse.self, from: outboundLine)
    #expect(response.id == .requestidoption1("auth-1"))
    #expect(
      response.result
        == .object([
          "accessToken": .string("access-token"),
          "chatgptAccountId": .string("account-id"),
        ]))

    await connection.close()
  }

  @Test("Client binding rejects generated server request with JSON-RPC error")
  func clientBindingRejectsGeneratedServerRequestWithJSONRPCError() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var iterator = connection.typedServerRequests.makeAsyncIterator()
    let request = authRefreshServerRequest(id: .requestidoption2(99))

    peer.receiveLine(try CodexAppServerConnectionFoundation.encodeLine(request))

    guard case .chatgptAuthTokensRefresh(let serverRequest) = try await iterator.next() else {
      Issue.record("Expected typed auth refresh request.")
      return
    }

    try await connection.rejectServerRequest(
      serverRequest,
      code: -32603,
      message: "declined",
      data: .object(["reason": .string("test")])
    )

    let outboundLine = await peer.nextSentLine()
    let error = try decode(Stable.JSONRPCError.self, from: outboundLine)
    #expect(error.id == .requestidoption2(99))
    #expect(error.error.code == -32603)
    #expect(error.error.message == "declined")
    #expect(error.error.data == .object(["reason": .string("test")]))

    await connection.close()
  }

  @Test("Client binding maps JSON-RPC error responses to explicit Swift errors")
  func clientBindingMapsJSONRPCErrorResponsesToExplicitSwiftErrors() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: nil, limit: nil),
        responseType: Stable.ModelListResponse.self
      )
    }

    let request = try decode(Stable.JSONRPCRequest.self, from: await peer.nextSentLine())
    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        Stable.JSONRPCError(
          error: .init(code: -32600, data: nil, message: "Not initialized"),
          id: request.id
        )
      ))

    do {
      _ = try await requestTask.value
      Issue.record("Expected JSON-RPC error.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .jsonRPCError(code: -32600, message: "Not initialized", data: nil))
    }

    await connection.close()
  }

  @Test("Client binding fails pending requests on malformed inbound JSON")
  func clientBindingFailsPendingRequestsOnMalformedInboundJSON() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: nil, limit: nil),
        responseType: Stable.ModelListResponse.self
      )
    }

    _ = await peer.nextSentLine()
    peer.receiveLine("{")

    do {
      _ = try await requestTask.value
      Issue.record("Expected malformed inbound failure.")
    } catch let error as CodexAppServerClientError {
      guard case .malformedInbound = error else {
        Issue.record("Expected malformed inbound error, got \(error).")
        return
      }
    }

    await connection.close()
  }

  @Test("Client binding fails pending requests when peer closes")
  func clientBindingFailsPendingRequestsWhenPeerCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: nil, limit: nil),
        responseType: Stable.ModelListResponse.self
      )
    }

    _ = await peer.nextSentLine()
    peer.finishInbound()

    do {
      _ = try await requestTask.value
      Issue.record("Expected peer-close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .peerClosed)
    }

    await connection.close()
  }

  @Test("Client binding cancels one pending request without corrupting read loop")
  func clientBindingCancelsOnePendingRequestWithoutCorruptingReadLoop() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)
    var notificationIterator = connection.notifications.makeAsyncIterator()

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: nil, limit: nil),
        responseType: Stable.ModelListResponse.self
      )
    }

    let request = try decode(Stable.JSONRPCRequest.self, from: await peer.nextSentLine())
    requestTask.cancel()

    do {
      _ = try await requestTask.value
      Issue.record("Expected request cancellation.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .requestCancelled)
    } catch is CancellationError {
      // Swift may surface task cancellation directly before the pending response
      // continuation resumes with the target-local cancellation error.
    }

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: Stable.ModelListResponse(data: [], nextCursor: "late")
      ))
    peer.receiveLine(try warningNotificationLine("still-open"))

    #expect(warningMessage(try await notificationIterator.next()) == "still-open")

    await connection.close()
  }

  @Test("Client binding close fails pending requests deterministically")
  func clientBindingCloseFailsPendingRequestsDeterministically() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendStableRequest(
        method: "model/list",
        params: Stable.ModelListParams(cursor: nil, includeHidden: nil, limit: nil),
        responseType: Stable.ModelListResponse.self
      )
    }

    _ = await peer.nextSentLine()
    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}

private struct LargeIntegerResponse: Decodable, Equatable {
  let value: Int64
}

private func makeClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_tests",
        title: "swift-codex Tests",
        version: "0.1.0"
      ),
      experimentalApi: false,
      optOutNotificationMethods: ["warning"]
    ),
    transportFactory: {
      peer
    }
  )
}

private func startReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeClient(peer: peer).start()
  }

  let initializeLine = await peer.nextSentLine()
  let initializeRequest = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializeRequest(from: initializeLine)
  peer.receiveLine(try initializeResponseLine(id: initializeRequest.id))

  let initializedLine = await peer.nextSentLine()
  _ = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializedNotification(from: initializedLine)

  return try await startTask.value
}

private func fixtureInitializeResponse() -> Stable.InitializeResponse {
  Stable.InitializeResponse(
    codexHome: "/tmp/swift-codex/codex-home",
    platformFamily: "unix",
    platformOs: "macos",
    userAgent: "Codex/swift-codex-client-binding-fixture"
  )
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: fixtureInitializeResponse()
  )
}

private func responseLine<T: Encodable>(
  id: Stable.RequestId,
  result: T
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.JSONRPCResponse(id: id, result: try Stable.JSONValue(result))
  )
}

private func warningNotificationLine(_ message: String) throws -> String {
  let notification = Stable.ServerNotification.warningnotification(
    .init(method: .warning, params: .init(message: message, threadId: nil))
  )

  return try CodexAppServerConnectionFoundation.encodeLine(notification)
}

private func warningMessage(_ notification: Stable.ServerNotification?) -> String? {
  guard case .warningnotification(let value) = notification else {
    return nil
  }

  return value.params.message
}

private func modelListRequestIDsByCursor(
  _ lines: [String]
) throws -> [String: Stable.RequestId] {
  try lines.reduce(into: [:]) { result, line in
    let clientRequest = try decode(Stable.ClientRequest.self, from: line)
    guard case .modelListRequest(let request) = clientRequest else {
      return
    }
    if let cursor = request.params.cursor {
      result[cursor] = request.id
    }
  }
}

private func authRefreshServerRequest(id: Stable.RequestId) -> Stable.ServerRequest {
  .accountChatgptAuthTokensRefreshRequest(
    .init(
      id: id,
      method: .accountChatgptAuthTokensRefresh,
      params: .init(previousAccountId: nil, reason: .unauthorized)
    )
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
