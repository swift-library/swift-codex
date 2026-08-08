import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Config Model Account Binding")
struct CodexAppServerConfigModelAccountBindingTests {
  @Test("Config, model, and feature bindings send generated stable requests")
  func configModelAndFeatureBindingsSendGeneratedStableRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startConfigModelAccountReadyConnection(peer: peer)

    let modelTask = Task {
      try await connection.modelList(.init(cursor: "cursor-1", includeHidden: true, limit: 2))
    }
    guard case .modelListRequest(let model) = try await nextRequest(peer) else {
      Issue.record("Expected model/list generated request.")
      return
    }
    #expect(model.method == .modelList)
    #expect(model.params.cursor == "cursor-1")
    #expect(model.params.includeHidden == true)
    #expect(model.params.limit == 2)
    peer.receiveLine(
      try responseLine(
        id: model.id,
        result: Stable.ModelListResponse(data: [], nextCursor: "cursor-2")
      ))
    #expect(try await modelTask.value.nextCursor == "cursor-2")

    let featureListTask = Task {
      try await connection.experimentalFeatureList(.init(cursor: "features-1", limit: 1))
    }
    guard case .experimentalfeatureListRequest(let featureList) = try await nextRequest(peer) else {
      Issue.record("Expected experimentalFeature/list generated request.")
      return
    }
    #expect(featureList.method == .experimentalfeatureList)
    #expect(featureList.params.cursor == "features-1")
    peer.receiveLine(
      try responseLine(
        id: featureList.id,
        result: Stable.ExperimentalFeatureListResponse(data: [])
      ))
    #expect(try await featureListTask.value.data.isEmpty)

    let featureSetTask = Task {
      try await connection.experimentalFeatureEnablementSet(.init(enablement: ["realtime": true]))
    }
    guard
      case .experimentalfeatureEnablementSetRequest(let featureSet) = try await nextRequest(peer)
    else {
      Issue.record("Expected experimentalFeature/enablement/set generated request.")
      return
    }
    #expect(featureSet.method == .experimentalfeatureEnablementSet)
    #expect(featureSet.params.enablement == ["realtime": true])
    peer.receiveLine(
      try responseLine(
        id: featureSet.id,
        result: Stable.ExperimentalFeatureEnablementSetResponse(enablement: ["realtime": true])
      ))
    #expect(try await featureSetTask.value.enablement["realtime"] == true)

    let configReadTask = Task {
      try await connection.configRead(.init(cwd: "/tmp/swift-codex/project", includeLayers: true))
    }
    guard case .configReadRequest(let configRead) = try await nextRequest(peer) else {
      Issue.record("Expected config/read generated request.")
      return
    }
    #expect(configRead.method == .configRead)
    #expect(configRead.params.cwd == "/tmp/swift-codex/project")
    #expect(configRead.params.includeLayers == true)
    peer.receiveLine(
      try responseLine(
        id: configRead.id,
        result: Stable.ConfigReadResponse(
          config: .init(model: "gpt-5.1-codex"),
          origins: [:]
        )
      ))
    #expect(try await configReadTask.value.config.model == "gpt-5.1-codex")

    let valueWriteTask = Task {
      try await connection.configValueWrite(
        .init(
          keyPath: "model",
          mergeStrategy: .replace,
          value: .string("gpt-5.1-codex")
        ))
    }
    guard case .configValueWriteRequest(let valueWrite) = try await nextRequest(peer) else {
      Issue.record("Expected config/value/write generated request.")
      return
    }
    #expect(valueWrite.method == .configValueWrite)
    #expect(valueWrite.params.keyPath == "model")
    #expect(valueWrite.params.value == .string("gpt-5.1-codex"))
    peer.receiveLine(
      try responseLine(
        id: valueWrite.id,
        result: Stable.ConfigWriteResponse(
          filePath: "/tmp/swift-codex/config.toml",
          status: .ok,
          version: "v2"
        )
      ))
    #expect(try await valueWriteTask.value.version == "v2")

    let batchWriteTask = Task {
      try await connection.configBatchWrite(
        .init(
          edits: [
            .init(
              keyPath: "approval_policy",
              mergeStrategy: .upsert,
              value: .string("on-request")
            )
          ],
          reloadUserConfig: true
        ))
    }
    guard case .configBatchWriteRequest(let batchWrite) = try await nextRequest(peer) else {
      Issue.record("Expected config/batchWrite generated request.")
      return
    }
    #expect(batchWrite.method == .configBatchWrite)
    #expect(batchWrite.params.edits.map(\.keyPath) == ["approval_policy"])
    #expect(batchWrite.params.reloadUserConfig == true)
    peer.receiveLine(
      try responseLine(
        id: batchWrite.id,
        result: Stable.ConfigWriteResponse(
          filePath: "/tmp/swift-codex/config.toml",
          status: .ok,
          version: "v3"
        )
      ))
    #expect(try await batchWriteTask.value.version == "v3")

    let requirementsTask = Task {
      try await connection.configRequirementsRead()
    }
    guard case .configrequirementsReadRequest(let requirements) = try await nextRequest(peer) else {
      Issue.record("Expected configRequirements/read generated request.")
      return
    }
    #expect(requirements.method == .configrequirementsRead)
    #expect(requirements.params == nil)
    peer.receiveLine(
      try responseLine(
        id: requirements.id,
        result: Stable.ConfigRequirementsReadResponse(
          requirements: .init(featureRequirements: ["realtime": false])
        )
      ))
    #expect(
      try await requirementsTask.value.requirements?.featureRequirements == ["realtime": false])

    await connection.close()
  }

  @Test("Account bindings send generated stable requests")
  func accountBindingsSendGeneratedStableRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startConfigModelAccountReadyConnection(peer: peer)

    let readTask = Task {
      try await connection.accountRead(.init(refreshToken: true))
    }
    guard case .accountReadRequest(let read) = try await nextRequest(peer) else {
      Issue.record("Expected account/read generated request.")
      return
    }
    #expect(read.method == .accountRead)
    #expect(read.params.refreshToken == true)
    peer.receiveLine(
      try responseLine(
        id: read.id,
        result: Stable.GetAccountResponse(account: nil, requiresOpenaiAuth: true)
      ))
    #expect(try await readTask.value.requiresOpenaiAuth)

    let loginTask = Task {
      try await connection.accountLoginStart(
        .apikey(
          .init(
            apiKey: "sk-test",
            type: .apikey
          )))
    }
    guard case .accountLoginStartRequest(let login) = try await nextRequest(peer) else {
      Issue.record("Expected account/login/start generated request.")
      return
    }
    #expect(login.method == .accountLoginStart)
    guard case .apikey(let loginParams) = login.params else {
      Issue.record("Expected apiKey login params.")
      return
    }
    #expect(loginParams.apiKey == "sk-test")
    peer.receiveLine(
      try responseLine(
        id: login.id,
        result: Stable.LoginAccountResponse.apikey(.init(type: .apikey))
      ))
    guard case .apikey = try await loginTask.value else {
      Issue.record("Expected apiKey login response.")
      return
    }

    let cancelTask = Task {
      try await connection.accountLoginCancel(.init(loginId: "login-1"))
    }
    guard case .accountLoginCancelRequest(let cancel) = try await nextRequest(peer) else {
      Issue.record("Expected account/login/cancel generated request.")
      return
    }
    #expect(cancel.method == .accountLoginCancel)
    #expect(cancel.params.loginId == "login-1")
    peer.receiveLine(
      try responseLine(
        id: cancel.id,
        result: Stable.CancelLoginAccountResponse(status: .canceled)
      ))
    #expect(try await cancelTask.value.status == .canceled)

    let logoutTask = Task {
      try await connection.accountLogout()
    }
    guard case .accountLogoutRequest(let logout) = try await nextRequest(peer) else {
      Issue.record("Expected account/logout generated request.")
      return
    }
    #expect(logout.method == .accountLogout)
    #expect(logout.params == nil)
    peer.receiveLine(
      try responseLine(
        id: logout.id,
        result: Stable.LogoutAccountResponse()
      ))
    #expect(try await logoutTask.value.isEmpty)

    let rateLimitsTask = Task {
      try await connection.accountRateLimitsRead()
    }
    guard case .accountRateLimitsReadRequest(let rateLimits) = try await nextRequest(peer) else {
      Issue.record("Expected account/rateLimits/read generated request.")
      return
    }
    #expect(rateLimits.method == .accountRateLimitsRead)
    #expect(rateLimits.params == nil)
    peer.receiveLine(
      try responseLine(
        id: rateLimits.id,
        result: Stable.GetAccountRateLimitsResponse(
          rateLimits: .init(primary: .init(usedPercent: 12))
        )
      ))
    #expect(try await rateLimitsTask.value.rateLimits.primary?.usedPercent == 12)

    let nudgeTask = Task {
      try await connection.accountSendAddCreditsNudgeEmail(.init(creditType: .usageLimit))
    }
    guard case .accountSendAddCreditsNudgeEmailRequest(let nudge) = try await nextRequest(peer)
    else {
      Issue.record("Expected account/sendAddCreditsNudgeEmail generated request.")
      return
    }
    #expect(nudge.method == .accountSendAddCreditsNudgeEmail)
    #expect(nudge.params.creditType == .usageLimit)
    peer.receiveLine(
      try responseLine(
        id: nudge.id,
        result: Stable.SendAddCreditsNudgeEmailResponse(status: .sent)
      ))
    #expect(try await nudgeTask.value.status == .sent)

    await connection.close()
  }

  @Test("Account events arrive on the notification stream")
  func accountEventsArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startConfigModelAccountReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(try accountUpdatedNotificationLine())

    guard
      case .accountUpdatedNotification(let rawAccountUpdated) = try await rawNotifications.next()
    else {
      Issue.record("Expected raw account/updated notification.")
      return
    }
    #expect(rawAccountUpdated.params.authMode == nil)

    peer.receiveLine(try accountRateLimitsUpdatedNotificationLine(usedPercent: 42))

    guard
      case .accountRateLimitsUpdatedNotification(let rawRateLimitsUpdated) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw account/rateLimits/updated notification.")
      return
    }
    #expect(rawRateLimitsUpdated.params.rateLimits.primary?.usedPercent == 42)

    await connection.close()
  }

  @Test("Config and account pending request fails when connection closes")
  func configAndAccountPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startConfigModelAccountReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.accountRead(.init(refreshToken: false))
    }

    guard case .accountReadRequest(let request) = try await nextRequest(peer) else {
      Issue.record("Expected account/read generated request.")
      return
    }
    #expect(request.params.refreshToken == false)

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startConfigModelAccountReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeConfigModelAccountClient(peer: peer).start()
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

private func makeConfigModelAccountClient(
  peer: CodexAppServerInMemoryLinePeer
) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_config_model_account_tests",
        title: "swift-codex Config Model Account Tests",
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
      userAgent: "Codex/swift-codex-config-model-account-fixture"
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

private func accountUpdatedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.accountUpdatedNotification(
      .init(
        method: .accountUpdated,
        params: .init()
      ))
  )
}

private func accountRateLimitsUpdatedNotificationLine(usedPercent: Int32) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.accountRateLimitsUpdatedNotification(
      .init(
        method: .accountRateLimitsUpdated,
        params: .init(rateLimits: .init(primary: .init(usedPercent: usedPercent)))
      ))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
