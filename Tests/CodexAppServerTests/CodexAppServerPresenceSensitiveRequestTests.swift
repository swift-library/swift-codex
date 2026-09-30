import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime

private typealias Stable = CodexAppServerProtocol.Stable
private typealias Experimental = CodexAppServerProtocol.Experimental

@Suite("CodexAppServer presence-sensitive requests")
struct CodexAppServerPresenceSensitiveRequestTests {
  @Test("Thread Section appearance preserves omitted, null, and replacement wire states")
  func threadSectionAppearanceUsesThreeWireStates() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startPresenceSensitiveConnection(peer: peer)

    try await expectThreadSectionUpdate(
      .unchanged,
      expectedAppearance: .omitted,
      connection: connection,
      peer: peer
    )
    try await expectThreadSectionUpdate(
      .clear,
      expectedAppearance: .null,
      connection: connection,
      peer: peer
    )
    try await expectThreadSectionUpdate(
      .replace(.init(color: "indigo", icon: "research")),
      expectedAppearance: .value(color: "indigo", icon: "research"),
      connection: connection,
      peer: peer
    )

    await connection.close()
  }

  @Test("Turn service tier preserves omitted, null, and replacement wire states")
  func turnServiceTierUsesThreeWireStates() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startPresenceSensitiveConnection(peer: peer)

    try await expectTurnSettingsUpdate(
      .unchanged,
      expectedServiceTier: .omitted,
      connection: connection,
      peer: peer
    )
    try await expectTurnSettingsUpdate(
      .clear,
      expectedServiceTier: .null,
      connection: connection,
      peer: peer
    )
    try await expectTurnSettingsUpdate(
      .replace("priority"),
      expectedServiceTier: .value("priority"),
      connection: connection,
      peer: peer
    )

    await connection.close()
  }
}

private enum ExpectedAppearance {
  case omitted
  case null
  case value(color: String, icon: String)
}

private enum ExpectedServiceTier {
  case omitted
  case null
  case value(String)
}

private func expectThreadSectionUpdate(
  _ update: CodexAppServerThreadSectionAppearanceUpdate,
  expectedAppearance: ExpectedAppearance,
  connection: CodexAppServerConnection,
  peer: CodexAppServerInMemoryLinePeer
) async throws {
  let requestTask = Task {
    try await connection.threadSectionUpdate(
      sectionID: "research",
      name: "Research",
      appearanceUpdate: update
    )
  }

  let line = await peer.nextSentLine()
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  )
  let params = try #require(object["params"] as? [String: Any])
  #expect(object["method"] as? String == "threadSection/update")
  #expect(params["sectionId"] as? String == "research")
  #expect(params["name"] as? String == "Research")

  switch expectedAppearance {
  case .omitted:
    #expect(!params.keys.contains("appearance"))
  case .null:
    #expect(params["appearance"] is NSNull)
  case .value(let color, let icon):
    let appearance = try #require(params["appearance"] as? [String: Any])
    #expect(appearance["color"] as? String == color)
    #expect(appearance["icon"] as? String == icon)
  }

  let request = try JSONDecoder().decode(Stable.JSONRPCRequest.self, from: Data(line.utf8))
  peer.receiveLine(
    try CodexAppServerConnectionFoundation.encodeLine(
      Stable.JSONRPCResponse(
        id: request.id,
        result: try Stable.JSONValue(
          Stable.ThreadSectionUpdateResponse(
            section: .init(id: "research", name: "Research")
          )
        )
      )
    )
  )
  _ = try await requestTask.value
}

private func expectTurnSettingsUpdate(
  _ update: CodexAppServerTurnServiceTierUpdate,
  expectedServiceTier: ExpectedServiceTier,
  connection: CodexAppServerConnection,
  peer: CodexAppServerInMemoryLinePeer
) async throws {
  let requestTask = Task {
    try await connection.turnSettingsUpdate(
      threadID: "thread-1",
      turnID: "turn-1",
      effort: "high",
      model: "gpt-5.6",
      summary: .concise,
      serviceTierUpdate: update
    )
  }

  let line = await peer.nextSentLine()
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  )
  let params = try #require(object["params"] as? [String: Any])
  #expect(object["method"] as? String == "turn/settings/update")
  #expect(params["threadId"] as? String == "thread-1")
  #expect(params["turnId"] as? String == "turn-1")
  #expect(params["effort"] as? String == "high")
  #expect(params["model"] as? String == "gpt-5.6")
  #expect(params["summary"] as? String == "concise")

  switch expectedServiceTier {
  case .omitted:
    #expect(!params.keys.contains("serviceTier"))
  case .null:
    #expect(params["serviceTier"] is NSNull)
  case .value(let serviceTier):
    #expect(params["serviceTier"] as? String == serviceTier)
  }

  let request = try JSONDecoder().decode(Stable.JSONRPCRequest.self, from: Data(line.utf8))
  peer.receiveLine(
    try CodexAppServerConnectionFoundation.encodeLine(
      Stable.JSONRPCResponse(
        id: request.id,
        result: try Stable.JSONValue(
          Experimental.TurnSettingsUpdateResponse(status: .applied)
        )
      )
    )
  )
  let response = try await requestTask.value
  #expect(response.status == .applied)
}

private func startPresenceSensitiveConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await CodexAppServerClient(
      sessionConfiguration: .init(
        clientInfo: .init(
          name: "swift_codex_presence_tests",
          title: "swift-codex Presence Tests",
          version: "0.1.0"
        ),
        experimentalApi: true
      ),
      transportFactory: { peer }
    ).start()
  }

  let initializeLine = await peer.nextSentLine()
  let initializeRequest = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializeRequest(from: initializeLine)
  peer.receiveLine(
    try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
      id: initializeRequest.id,
      response: .init(
        codexHome: "/tmp/swift-codex/codex-home",
        platformFamily: "unix",
        platformOs: "macos",
        userAgent: "Codex/swift-codex-presence-tests"
      )
    )
  )

  let initializedLine = await peer.nextSentLine()
  _ = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializedNotification(from: initializedLine)
  return try await startTask.value
}
