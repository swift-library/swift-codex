import CodexAppServerProtocol
import CodexAppServerRuntime
import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Lossless Messages", .timeLimit(.minutes(1)))
struct CodexAppServerLosslessTests {
  @Test("Adopted requests retain native options, unknown fields, and complete results")
  func adoptedRequestRetainsCompletePayloads() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    let params = Stable.JSONValue.object([
      "threadId": .string("thread-1"),
      "input": .array([]),
      "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
      "approvalPolicy": .object(["granular": .object(["request_permissions": .bool(true)])]),
      "futureField": .object(["nullable": .null, "integer": .number(.integer(Int64.max))]),
    ])
    let pending = Task { try await connection.sendRawRequest(method: "turn/start", params: params) }
    let request = try decode(Stable.JSONRPCRequest.self, await peer.nextSentLine())
    #expect(request.method == "turn/start")
    #expect(request.params == params)
    let result = Stable.JSONValue.object(["futureResult": params])
    peer.receiveLine(try encode(Stable.JSONRPCResponse(id: request.id, result: result)))
    #expect(try await pending.value == result)
    await connection.close()
  }

  @Test("Raw notifications retain unknown methods, explicit nulls, and envelope fields in order")
  func notificationsRetainCompleteEnvelopes() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    let payload = Stable.JSONValue.object([
      "method": .string("future/changed"), "params": .null,
      "futureEnvelopeField": .array([.number(.integer(Int64.max)), .bool(true)]),
    ])
    peer.receiveLine(try encode(payload))
    peer.receiveLine(#"{"method":"future/finished"}"#)
    var raw = connection.rawNotifications.makeAsyncIterator()
    let first = try #require(await raw.next())
    #expect(first.method == "future/changed")
    #expect(first.params == .null)
    #expect(first.payload == payload)
    #expect(try await raw.next()?.method == "future/finished")
    var typed = connection.notifications.makeAsyncIterator()
    #expect(try await typed.next() == nil)
    await connection.close()
  }

  @Test("Unknown server requests resolve once with arbitrary native response shapes")
  func rawServerRequestResolvesOnce() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    let payload = Stable.JSONValue.object([
      "id": .string("future-request"), "method": .string("future/approval"),
      "params": .object(["nativePermission": .string("future-kind")]),
      "trace": .object(["opaque": .string("fixture")]),
    ])
    peer.receiveLine(try encode(payload))
    var requests = connection.rawServerRequests.makeAsyncIterator()
    let request = try #require(await requests.next())
    #expect(request.payload == payload)
    #expect(request.id == .requestidoption1("future-request"))
    let response = Stable.JSONValue.object([
      "decision": .object([
        "applyNetworkPolicyAmendment": .object([
          "network_policy_amendment": .object([
            "action": .string("allow"), "host": .string("example.invalid"),
          ])
        ])
      ]),
      "futureResponse": .null,
    ])
    try await connection.resolveServerRequest(request, with: response)
    let sent = try decode(Stable.JSONRPCResponse.self, await peer.nextSentLine())
    #expect(sent.id == request.id)
    #expect(sent.result == response)
    await #expect(throws: CodexAppServerClientError.serverRequestAlreadyCompleted(id: request.id)) {
      try await connection.rejectServerRequest(request, code: -1, message: "already complete")
    }
    await connection.close()
  }

  @Test("A raw handle cannot resolve a same-id request on another connection")
  func rawHandleIsConnectionOwned() async throws {
    let firstPeer = CodexAppServerInMemoryLinePeer()
    let secondPeer = CodexAppServerInMemoryLinePeer()
    let first = CodexAppServerConnection(transport: firstPeer, inboundMessageMode: .raw)
    let second = CodexAppServerConnection(transport: secondPeer, inboundMessageMode: .raw)
    firstPeer.receiveLine(#"{"id":1,"method":"currentTime/read","params":{}}"#)
    secondPeer.receiveLine(#"{"id":1,"method":"currentTime/read","params":{}}"#)
    var firstRequests = first.rawServerRequests.makeAsyncIterator()
    var secondRequests = second.rawServerRequests.makeAsyncIterator()
    let firstRequest = try #require(await firstRequests.next())
    let secondRequest = try #require(await secondRequests.next())
    await #expect(throws: CodexAppServerClientError.foreignServerRequest(id: firstRequest.id)) {
      try await second.resolveServerRequest(firstRequest, with: Stable.JSONValue.null)
    }
    try await second.rejectServerRequest(
      secondRequest, code: -32_601, message: "Unsupported request")
    let response = try decode(Stable.JSONRPCError.self, await secondPeer.nextSentLine())
    #expect(response.error.code == -32_601)
    await first.close()
    await second.close()
  }

  @Test("Malformed raw envelopes fail pending requests and inbound streams")
  func malformedEnvelopeFailsConnection() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    _ = await peer.nextSentLine()
    peer.receiveLine(#"{"id":1,"method":"future/request","result":{}}"#)
    await #expect(throws: CodexAppServerClientError.self) { try await pending.value }
    var notifications = connection.rawNotifications.makeAsyncIterator()
    await #expect(throws: CodexAppServerClientError.self) { try await notifications.next() }
    await connection.close()
  }

  @Test("A completed raw handle cannot resolve a later request that reuses its id")
  func completedHandleDoesNotResolveReusedID() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    var requests = connection.rawServerRequests.makeAsyncIterator()
    peer.receiveLine(#"{"id":1,"method":"currentTime/read"}"#)
    let first = try #require(await requests.next())
    try await connection.resolveServerRequest(first, with: Stable.JSONValue.null)
    _ = await peer.nextSentLine()
    peer.receiveLine(#"{"id":1,"method":"currentTime/read"}"#)
    let second = try #require(await requests.next())
    await #expect(throws: CodexAppServerClientError.serverRequestAlreadyCompleted(id: first.id)) {
      try await connection.resolveServerRequest(first, with: Stable.JSONValue.null)
    }
    try await connection.resolveServerRequest(second, with: Stable.JSONValue.object([:]))
    let response = try decode(Stable.JSONRPCResponse.self, await peer.nextSentLine())
    #expect(response.result == .object([:]))
    await connection.close()
  }

  @Test("Raw request cancellation consumes a late response without retiring the connection")
  func cancellationPreservesCorrelation() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = CodexAppServerConnection(transport: peer, inboundMessageMode: .raw)
    let pending = Task { try await connection.sendRawRequest(method: "config/read") }
    let request = try decode(Stable.JSONRPCRequest.self, await peer.nextSentLine())
    pending.cancel()
    await #expect(throws: CodexAppServerClientError.requestCancelled) { try await pending.value }
    peer.receiveLine(try encode(Stable.JSONRPCResponse(id: request.id, result: .null)))
    peer.receiveLine(#"{"method":"future/stillConnected"}"#)
    var notifications = connection.rawNotifications.makeAsyncIterator()
    #expect(try await notifications.next()?.method == "future/stillConnected")
    await connection.close()
    #expect(try await notifications.next() == nil)
  }
}

private func encode(_ value: some Encodable) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(value)
}

private func decode<T: Decodable>(_ type: T.Type, _ line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
