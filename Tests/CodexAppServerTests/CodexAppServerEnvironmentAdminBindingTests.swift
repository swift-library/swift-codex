import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Environment Admin Binding")
struct CodexAppServerEnvironmentAdminBindingTests {
  @Test("Environment/admin binding sends generated stable requests")
  func environmentAdminBindingSendsGeneratedStableRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEnvironmentAdminReadyConnection(peer: peer)

    let reloadTask = Task {
      try await connection.configMcpServerReload()
    }
    guard case .configMcpServerReloadRequest(let reload) = try await nextRequest(peer) else {
      Issue.record("Expected config/mcpServer/reload generated request.")
      return
    }
    #expect(reload.method == .configMcpServerReload)
    #expect(reload.params == nil)
    let reloadResponse: Stable.McpServerRefreshResponse = ["reloaded": .bool(true)]
    peer.receiveLine(try responseLine(id: reload.id, result: reloadResponse))
    #expect(try await reloadTask.value["reloaded"] == .bool(true))

    let feedbackTask = Task {
      try await connection.feedbackUpload(
        .init(
          classification: "bug",
          extraLogFiles: ["/tmp/swift-codex/codex.log"],
          includeLogs: true,
          reason: "unexpected app-server state",
          tags: ["area": "app-server"],
          threadId: "thread-1"
        ))
    }
    guard case .feedbackUploadRequest(let feedback) = try await nextRequest(peer) else {
      Issue.record("Expected feedback/upload generated request.")
      return
    }
    #expect(feedback.method == .feedbackUpload)
    #expect(feedback.params.classification == "bug")
    #expect(feedback.params.extraLogFiles == ["/tmp/swift-codex/codex.log"])
    #expect(feedback.params.includeLogs == true)
    #expect(feedback.params.reason == "unexpected app-server state")
    #expect(feedback.params.tags == ["area": "app-server"])
    #expect(feedback.params.threadId == "thread-1")
    peer.receiveLine(
      try responseLine(
        id: feedback.id,
        result: Stable.FeedbackUploadResponse(threadId: "thread-1")
      ))
    #expect(try await feedbackTask.value.threadId == "thread-1")

    let migrationItem = Stable.ExternalAgentConfigMigrationItem(
      cwd: "/tmp/swift-codex/project",
      description: "Import AGENTS.md",
      itemType: .agentsMD
    )

    let detectTask = Task {
      try await connection.externalAgentConfigDetect(
        .init(
          cwds: ["/tmp/swift-codex/project"],
          includeHome: true
        ))
    }
    guard case .externalagentconfigDetectRequest(let detect) = try await nextRequest(peer) else {
      Issue.record("Expected externalAgentConfig/detect generated request.")
      return
    }
    #expect(detect.method == .externalagentconfigDetect)
    #expect(detect.params.cwds == ["/tmp/swift-codex/project"])
    #expect(detect.params.includeHome == true)
    peer.receiveLine(
      try responseLine(
        id: detect.id,
        result: Stable.ExternalAgentConfigDetectResponse(items: [migrationItem])
      ))
    #expect(try await detectTask.value.items == [migrationItem])

    let importTask = Task {
      try await connection.externalAgentConfigImport(.init(migrationItems: [migrationItem]))
    }
    guard case .externalagentconfigImportRequest(let importRequest) = try await nextRequest(peer)
    else {
      Issue.record("Expected externalAgentConfig/import generated request.")
      return
    }
    #expect(importRequest.method == .externalagentconfigImport)
    #expect(importRequest.params.migrationItems == [migrationItem])
    let importResponse = Stable.ExternalAgentConfigImportResponse(importId: "import-1")
    peer.receiveLine(try responseLine(id: importRequest.id, result: importResponse))
    #expect(try await importTask.value.importId == "import-1")

    let sandboxTask = Task {
      try await connection.windowsSandboxSetupStart(
        .init(
          cwd: "/tmp/swift-codex/project",
          mode: .elevated
        ))
    }
    guard case .windowssandboxSetupStartRequest(let sandbox) = try await nextRequest(peer) else {
      Issue.record("Expected windowsSandbox/setupStart generated request.")
      return
    }
    #expect(sandbox.method == .windowssandboxSetupStart)
    #expect(sandbox.params.cwd == "/tmp/swift-codex/project")
    #expect(sandbox.params.mode == .elevated)
    peer.receiveLine(
      try responseLine(
        id: sandbox.id,
        result: Stable.WindowsSandboxSetupStartResponse(started: true)
      ))
    #expect(try await sandboxTask.value.started)

    await connection.close()
  }

  @Test("Environment and admin events arrive on the notification stream")
  func environmentAdminEventsArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEnvironmentAdminReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(try externalAgentConfigImportCompletedNotificationLine())
    guard
      case .externalagentconfigImportCompletedNotification(let rawImportCompleted) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw externalAgentConfig/import/completed notification.")
      return
    }
    #expect(rawImportCompleted.params.importId == "import-1")
    #expect(rawImportCompleted.params.itemTypeResults == [])

    peer.receiveLine(try windowsWorldWritableWarningNotificationLine())
    guard
      case .windowsWorldWritableWarningNotification(let rawWorldWritable) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw windows/worldWritableWarning notification.")
      return
    }
    #expect(rawWorldWritable.params.failedScan == false)
    #expect(rawWorldWritable.params.extraCount == 2)
    #expect(rawWorldWritable.params.samplePaths == ["/tmp/world-writable"])

    peer.receiveLine(try windowsSandboxSetupCompletedNotificationLine())
    guard
      case .windowssandboxSetupCompletedNotification(let rawSandboxCompleted) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw windowsSandbox/setupCompleted notification.")
      return
    }
    #expect(rawSandboxCompleted.params.success == true)
    #expect(rawSandboxCompleted.params.mode == .elevated)
    #expect(rawSandboxCompleted.params.error == nil)

    await connection.close()
  }

  @Test("Environment/admin pending request fails when connection closes")
  func environmentAdminPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEnvironmentAdminReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.windowsSandboxSetupStart(
        .init(
          cwd: "/tmp/swift-codex/project",
          mode: .unelevated
        ))
    }

    guard case .windowssandboxSetupStartRequest(let request) = try await nextRequest(peer) else {
      Issue.record("Expected windowsSandbox/setupStart generated request.")
      return
    }
    #expect(request.params.mode == .unelevated)

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startEnvironmentAdminReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeEnvironmentAdminClient(peer: peer).start()
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

private func makeEnvironmentAdminClient(
  peer: CodexAppServerInMemoryLinePeer
) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_environment_admin_tests",
        title: "swift-codex Environment Admin Tests",
        version: "0.1.0"
      )
    ),
    transportFactory: {
      peer
    }
  )
}

private func nextRequest(_ peer: CodexAppServerInMemoryLinePeer) async throws
  -> Stable.ClientRequest
{
  try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: .init(
      codexHome: "/tmp/swift-codex/codex-home",
      platformFamily: "unix",
      platformOs: "macos",
      userAgent: "Codex/swift-codex-environment-admin-fixture"
    )
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

private func externalAgentConfigImportCompletedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.externalagentconfigImportCompletedNotification(
      .init(
        method: .externalagentconfigImportCompleted,
        params: .init(importId: "import-1", itemTypeResults: [])
      ))
  )
}

private func windowsWorldWritableWarningNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.windowsWorldWritableWarningNotification(
      .init(
        method: .windowsWorldWritableWarning,
        params: .init(
          extraCount: 2,
          failedScan: false,
          samplePaths: ["/tmp/world-writable"]
        )
      ))
  )
}

private func windowsSandboxSetupCompletedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.windowssandboxSetupCompletedNotification(
      .init(
        method: .windowssandboxSetupCompleted,
        params: .init(
          mode: .elevated,
          success: true
        )
      ))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
