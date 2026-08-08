import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServerClient")
struct CodexAppServerClientTests {
  @Test("client performs handshake and typed request through injected transport")
  func clientPerformsHandshakeAndTypedRequestThroughInjectedTransport() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let client = CodexAppServerClient(
      sessionConfiguration: .init(
        clientInfo: .init(
          name: "swift_codex_client_tests",
          title: "Client Tests",
          version: "0.1.0"
        ),
        optOutNotificationMethods: ["warning"]
      ),
      transportFactory: {
        peer
      }
    )
    let startTask = Task {
      try await client.start()
    }

    let initializeLine = await peer.nextSentLine()
    let initializeRequest = try decode(Stable.ClientRequest.self, from: initializeLine)
    guard case .initializerequest(let initialize) = initializeRequest else {
      Issue.record("Expected initialize request.")
      return
    }
    #expect(initialize.params.clientInfo.name == "swift_codex_client_tests")
    #expect(initialize.params.capabilities?.optOutNotificationMethods == ["warning"])

    peer.receiveLine(
      try responseLine(
        id: initialize.id,
        result: Stable.InitializeResponse(
          codexHome: "/tmp/swift-codex/codex-home",
          platformFamily: "unix",
          platformOs: "macos",
          userAgent: "Codex/swift-codex-client-tests"
        )
      ))

    let initializedLine = await peer.nextSentLine()
    let initialized = try decode(Stable.ClientNotification.self, from: initializedLine)
    guard case .initializednotification = initialized else {
      Issue.record("Expected initialized notification.")
      return
    }

    let connection = try await startTask.value
    let requestTask = Task {
      try await connection.modelList(
        Stable.ModelListParams(cursor: nil, includeHidden: true, limit: 1)
      )
    }

    let modelListLine = await peer.nextSentLine()
    let modelListRequest = try decode(Stable.ClientRequest.self, from: modelListLine)
    guard case .modelListRequest(let modelList) = modelListRequest else {
      Issue.record("Expected model/list request.")
      return
    }
    #expect(modelList.params.includeHidden == true)

    peer.receiveLine(
      try responseLine(
        id: modelList.id,
        result: Stable.ModelListResponse(data: [], nextCursor: "done")
      ))

    #expect(try await requestTask.value.nextCursor == "done")
    await connection.close()
  }
}

private func responseLine(id: Stable.RequestId, result: some Encodable) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.JSONRPCResponse(id: id, result: try Stable.JSONValue(result))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
