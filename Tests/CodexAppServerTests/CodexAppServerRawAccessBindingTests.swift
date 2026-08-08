import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Raw Access Binding")
struct CodexAppServerRawAccessBindingTests {
  @Test("Raw request escape hatch sends bounded JSON-RPC and preserves dynamic result")
  func rawRequestEscapeHatchSendsBoundedJSONRPCAndPreservesDynamicResult() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.sendRawRequest(
        method: "diagnostic/futureMethod",
        params: FutureParams(featureFlag: true)
      )
    }

    let request = try decode(Stable.JSONRPCRequest.self, from: await peer.nextSentLine())
    #expect(request.method == "diagnostic/futureMethod")
    #expect(request.params == .object(["featureFlag": .bool(true)]))

    let result = Stable.JSONValue.object([
      "ok": .bool(true),
      "detail": .object(["source": .string("fixture")]),
    ])
    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        Stable.JSONRPCResponse(id: request.id, result: result)
      ))

    #expect(try await requestTask.value == result)

    await connection.close()
  }

  @Test("Raw notification escape hatch sends bounded JSON-RPC notification")
  func rawNotificationEscapeHatchSendsBoundedJSONRPCNotification() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    try await connection.sendRawNotification(
      method: "diagnostic/ping",
      params: Stable.JSONValue.object(["kind": .string("probe")])
    )

    let notification = try decode(Stable.JSONRPCNotification.self, from: await peer.nextSentLine())
    #expect(notification.method == "diagnostic/ping")
    #expect(notification.params == .object(["kind": .string("probe")]))

    await connection.close()
  }

  @Test("Raw access rejects invalid and explicitly excluded method names")
  func rawAccessRejectsInvalidAndExplicitlyExcludedMethodNames() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startReadyConnection(peer: peer)

    do {
      _ = try await connection.sendRawRequest(method: " initialize")
      Issue.record("Expected invalid raw method failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .invalidRawMethod(" initialize"))
    }

    do {
      _ = try await connection.sendRawRequest(method: "initialize")
      Issue.record("Expected raw method deny-list failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .rawMethodNotAllowed("initialize"))
    }

    do {
      try await connection.sendRawNotification(method: "fuzzyFileSearch")
      Issue.record("Expected deprecated raw method deny-list failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .rawMethodNotAllowed("fuzzyFileSearch"))
    }

    await connection.close()
  }

}
private struct FutureParams: Encodable, Sendable {
  let featureFlag: Bool
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
      optOutNotificationMethods: []
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
    userAgent: "Codex/swift-codex-raw-access-fixture"
  )
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: fixtureInitializeResponse()
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
