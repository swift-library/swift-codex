import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Ecosystem Binding")
struct CodexAppServerEcosystemBindingTests {
  @Test("Ecosystem binding sends skills and marketplace requests")
  func ecosystemBindingSendsSkillsAndMarketplaceRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEcosystemReadyConnection(peer: peer)

    let skillsTask = Task {
      try await connection.skillsList(
        .init(
          cwds: ["/tmp/swift-codex/project"],
          forceReload: true
        ))
    }
    guard case .skillsListRequest(let skills) = try await nextRequest(peer) else {
      Issue.record("Expected skills/list generated request.")
      return
    }
    #expect(skills.method == .skillsList)
    #expect(skills.params.cwds == ["/tmp/swift-codex/project"])
    #expect(skills.params.forceReload == true)
    peer.receiveLine(
      try responseLine(
        id: skills.id,
        result: Stable.SkillsListResponse(data: [
          .init(
            cwd: "/tmp/swift-codex/project",
            errors: [],
            skills: [
              .init(
                description: "Build SwiftPM packages",
                enabled: true,
                name: "swiftpm-macos",
                path: "/tmp/skills/swiftpm-macos",
                scope: .user,
                shortDescription: "SwiftPM"
              )
            ]
          )
        ])
      ))
    #expect(try await skillsTask.value.data.first?.skills.first?.name == "swiftpm-macos")

    let skillsConfigTask = Task {
      try await connection.skillsConfigWrite(
        .init(
          enabled: false,
          name: "swiftpm-macos"
        ))
    }
    guard case .skillsConfigWriteRequest(let skillsConfig) = try await nextRequest(peer) else {
      Issue.record("Expected skills/config/write generated request.")
      return
    }
    #expect(skillsConfig.method == .skillsConfigWrite)
    #expect(skillsConfig.params.enabled == false)
    #expect(skillsConfig.params.name == "swiftpm-macos")
    peer.receiveLine(
      try responseLine(
        id: skillsConfig.id,
        result: Stable.SkillsConfigWriteResponse(effectiveEnabled: false)
      ))
    #expect(try await skillsConfigTask.value.effectiveEnabled == false)

    let marketplaceAddTask = Task {
      try await connection.marketplaceAdd(
        .init(
          refName: "main",
          source: "https://example.test/plugins.git",
          sparsePaths: ["plugins/swiftpm"]
        ))
    }
    guard case .marketplaceAddRequest(let add) = try await nextRequest(peer) else {
      Issue.record("Expected marketplace/add generated request.")
      return
    }
    #expect(add.method == .marketplaceAdd)
    #expect(add.params.refName == "main")
    #expect(add.params.source == "https://example.test/plugins.git")
    #expect(add.params.sparsePaths == ["plugins/swiftpm"])
    peer.receiveLine(
      try responseLine(
        id: add.id,
        result: Stable.MarketplaceAddResponse(
          alreadyAdded: false,
          installedRoot: "/tmp/swift-codex/marketplaces/example",
          marketplaceName: "example"
        )
      ))
    #expect(try await marketplaceAddTask.value.marketplaceName == "example")

    let marketplaceRemoveTask = Task {
      try await connection.marketplaceRemove(.init(marketplaceName: "example"))
    }
    guard case .marketplaceRemoveRequest(let remove) = try await nextRequest(peer) else {
      Issue.record("Expected marketplace/remove generated request.")
      return
    }
    #expect(remove.method == .marketplaceRemove)
    #expect(remove.params.marketplaceName == "example")
    peer.receiveLine(
      try responseLine(
        id: remove.id,
        result: Stable.MarketplaceRemoveResponse(
          installedRoot: "/tmp/swift-codex/marketplaces/example",
          marketplaceName: "example"
        )
      ))
    #expect(
      try await marketplaceRemoveTask.value.installedRoot == "/tmp/swift-codex/marketplaces/example"
    )

    await connection.close()
  }

  @Test("Ecosystem binding sends plugin and app requests")
  func ecosystemBindingSendsPluginAndAppRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEcosystemReadyConnection(peer: peer)

    let pluginListTask = Task {
      try await connection.pluginList(.init(cwds: ["/tmp/swift-codex/project"]))
    }
    guard case .pluginListRequest(let pluginList) = try await nextRequest(peer) else {
      Issue.record("Expected plugin/list generated request.")
      return
    }
    #expect(pluginList.method == .pluginList)
    #expect(pluginList.params.cwds == ["/tmp/swift-codex/project"])
    peer.receiveLine(
      try responseLine(
        id: pluginList.id,
        result: Stable.PluginListResponse(
          featuredPluginIds: ["swiftpm"],
          marketplaces: [
            .init(
              name: "example",
              path: "/tmp/swift-codex/marketplaces/example",
              plugins: [pluginSummary()]
            )
          ]
        )
      ))
    #expect(try await pluginListTask.value.featuredPluginIds == ["swiftpm"])

    let pluginReadTask = Task {
      try await connection.pluginRead(
        .init(
          marketplacePath: "/tmp/swift-codex/marketplaces/example",
          pluginName: "swiftpm"
        ))
    }
    guard case .pluginReadRequest(let pluginRead) = try await nextRequest(peer) else {
      Issue.record("Expected plugin/read generated request.")
      return
    }
    #expect(pluginRead.method == .pluginRead)
    #expect(pluginRead.params.marketplacePath == "/tmp/swift-codex/marketplaces/example")
    #expect(pluginRead.params.pluginName == "swiftpm")
    peer.receiveLine(
      try responseLine(
        id: pluginRead.id,
        result: Stable.PluginReadResponse(plugin: pluginDetail())
      ))
    #expect(try await pluginReadTask.value.plugin.summary.id == "plugin-swiftpm")

    let pluginInstallTask = Task {
      try await connection.pluginInstall(
        .init(
          pluginName: "swiftpm",
          remoteMarketplaceName: "example"
        ))
    }
    guard case .pluginInstallRequest(let pluginInstall) = try await nextRequest(peer) else {
      Issue.record("Expected plugin/install generated request.")
      return
    }
    #expect(pluginInstall.method == .pluginInstall)
    #expect(pluginInstall.params.remoteMarketplaceName == "example")
    #expect(pluginInstall.params.pluginName == "swiftpm")
    peer.receiveLine(
      try responseLine(
        id: pluginInstall.id,
        result: Stable.PluginInstallResponse(
          appsNeedingAuth: [appSummary()],
          authPolicy: .onINSTALL
        )
      ))
    #expect(try await pluginInstallTask.value.appsNeedingAuth.map { $0.id } == ["app-swiftpm"])

    let pluginUninstallTask = Task {
      try await connection.pluginUninstall(.init(pluginId: "plugin-swiftpm"))
    }
    guard case .pluginUninstallRequest(let pluginUninstall) = try await nextRequest(peer) else {
      Issue.record("Expected plugin/uninstall generated request.")
      return
    }
    #expect(pluginUninstall.method == .pluginUninstall)
    #expect(pluginUninstall.params.pluginId == "plugin-swiftpm")
    let uninstallResponse: Stable.PluginUninstallResponse = ["removed": .bool(true)]
    peer.receiveLine(
      try responseLine(
        id: pluginUninstall.id,
        result: uninstallResponse
      ))
    #expect(try await pluginUninstallTask.value["removed"] == .bool(true))

    let appListTask = Task {
      try await connection.appList(
        .init(
          cursor: "apps-1",
          forceRefetch: true,
          limit: 5,
          threadId: "thread-1"
        ))
    }
    guard case .appListRequest(let appList) = try await nextRequest(peer) else {
      Issue.record("Expected app/list generated request.")
      return
    }
    #expect(appList.method == .appList)
    #expect(appList.params.cursor == "apps-1")
    #expect(appList.params.forceRefetch == true)
    #expect(appList.params.limit == 5)
    #expect(appList.params.threadId == "thread-1")
    peer.receiveLine(
      try responseLine(
        id: appList.id,
        result: Stable.AppsListResponse(
          data: [
            .init(id: "app-swiftpm", isEnabled: true, name: "SwiftPM")
          ],
          nextCursor: "apps-2"
        )
      ))
    let appListResponse = try await appListTask.value
    #expect(appListResponse.data.map(\.id) == ["app-swiftpm"])
    #expect(appListResponse.nextCursor == "apps-2")

    await connection.close()
  }

  @Test("Ecosystem events arrive on the notification stream")
  func ecosystemEventsArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEcosystemReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(try skillsChangedNotificationLine(cwd: "/tmp/swift-codex/project"))

    guard
      case .skillsChangedNotification(let rawSkillsChanged) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw skills/changed notification.")
      return
    }
    #expect(rawSkillsChanged.params["cwd"] == .string("/tmp/swift-codex/project"))

    peer.receiveLine(try appListUpdatedNotificationLine())

    guard
      case .appListUpdatedNotification(let rawAppListUpdated) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw app/list/updated notification.")
      return
    }
    #expect(rawAppListUpdated.params.data.map(\.id) == ["app-swiftpm"])

    await connection.close()
  }

  @Test("Ecosystem pending request fails when connection closes")
  func ecosystemPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startEcosystemReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.appList(.init(limit: 1))
    }

    guard case .appListRequest(let request) = try await nextRequest(peer) else {
      Issue.record("Expected app/list generated request.")
      return
    }
    #expect(request.params.limit == 1)

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startEcosystemReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeEcosystemClient(peer: peer).start()
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

private func makeEcosystemClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_ecosystem_tests",
        title: "swift-codex Ecosystem Tests",
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
      userAgent: "Codex/swift-codex-ecosystem-fixture"
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

private func skillsChangedNotificationLine(cwd: String) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.skillsChangedNotification(
      .init(
        method: .skillsChanged,
        params: ["cwd": .string(cwd)]
      ))
  )
}

private func appListUpdatedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.appListUpdatedNotification(
      .init(
        method: .appListUpdated,
        params: .init(data: [
          .init(id: "app-swiftpm", isEnabled: true, name: "SwiftPM")
        ])
      ))
  )
}

private func pluginSummary() -> Stable.PluginSummary {
  .init(
    authPolicy: .onUSE,
    enabled: true,
    id: "plugin-swiftpm",
    installPolicy: .available,
    installed: false,
    name: "swiftpm",
    source: .remote(.init(type: .remote))
  )
}

private func pluginDetail() -> Stable.PluginDetail {
  .init(
    appTemplates: [],
    apps: [appSummary()],
    description: "SwiftPM helper plugin",
    hooks: [],
    marketplaceName: "example",
    marketplacePath: "/tmp/swift-codex/marketplaces/example",
    mcpServers: [],
    skills: [
      .init(
        description: "Build SwiftPM packages",
        enabled: true,
        name: "swiftpm-macos",
        path: "/tmp/skills/swiftpm-macos"
      )
    ],
    summary: pluginSummary()
  )
}

private func appSummary() -> Stable.AppSummary {
  .init(
    description: "SwiftPM helper app",
    id: "app-swiftpm",
    name: "SwiftPM"
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
