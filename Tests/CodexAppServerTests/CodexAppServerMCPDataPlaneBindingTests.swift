import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer MCP Data Plane Binding")
struct CodexAppServerMCPDataPlaneBindingTests {
  @Test("MCP app-server binding sends OAuth and status requests")
  func mcpAppServerBindingSendsOauthAndStatusRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startMCPReadyConnection(peer: peer)

    let oauthTask = Task {
      try await connection.mcpServerOauthLogin(
        .init(
          name: "github",
          scopes: ["repo:read"],
          timeoutSecs: 30
        ))
    }
    guard case .mcpserverOauthLoginRequest(let oauth) = try await nextRequest(peer) else {
      Issue.record("Expected mcpServer/oauth/login generated request.")
      return
    }
    #expect(oauth.method == .mcpserverOauthLogin)
    #expect(oauth.params.name == "github")
    #expect(oauth.params.scopes == ["repo:read"])
    #expect(oauth.params.timeoutSecs == 30)
    peer.receiveLine(
      try responseLine(
        id: oauth.id,
        result: Stable.McpServerOauthLoginResponse(
          authorizationUrl: "https://example.test/oauth"
        )
      ))
    #expect(try await oauthTask.value.authorizationUrl == "https://example.test/oauth")

    let statusTask = Task {
      try await connection.mcpServerStatusList(
        .init(
          cursor: "mcp-cursor-1",
          detail: .full,
          limit: 10
        ))
    }
    guard case .mcpserverstatusListRequest(let status) = try await nextRequest(peer) else {
      Issue.record("Expected mcpServerStatus/list generated request.")
      return
    }
    #expect(status.method == .mcpserverstatusList)
    #expect(status.params.cursor == "mcp-cursor-1")
    #expect(status.params.detail == .full)
    #expect(status.params.limit == 10)
    peer.receiveLine(
      try responseLine(
        id: status.id,
        result: Stable.ListMcpServerStatusResponse(
          data: [
            .init(
              authStatus: .oauth,
              name: "github",
              resourceTemplates: [],
              resources: [],
              tools: [:]
            )
          ],
          nextCursor: "mcp-cursor-2"
        )
      ))
    let statusResponse = try await statusTask.value
    #expect(statusResponse.data.map(\.name) == ["github"])
    #expect(statusResponse.nextCursor == "mcp-cursor-2")

    await connection.close()
  }

  @Test("MCP app-server binding sends resource read and tool call requests")
  func mcpAppServerBindingSendsResourceReadAndToolCallRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startMCPReadyConnection(peer: peer)

    let resourceTask = Task {
      try await connection.mcpServerResourceRead(
        .init(
          server: "filesystem",
          threadId: "thread-1",
          uri: "file:///README.md"
        ))
    }
    guard case .mcpserverResourceReadRequest(let resource) = try await nextRequest(peer) else {
      Issue.record("Expected mcpServer/resource/read generated request.")
      return
    }
    #expect(resource.method == .mcpserverResourceRead)
    #expect(resource.params.server == "filesystem")
    #expect(resource.params.threadId == "thread-1")
    #expect(resource.params.uri == "file:///README.md")
    peer.receiveLine(
      try responseLine(
        id: resource.id,
        result: Stable.McpResourceReadResponse(contents: [
          .resourcecontentoption1(
            .init(
              mimeType: "text/markdown",
              text: "# swift-codex",
              uri: "file:///README.md"
            ))
        ])
      ))
    #expect(try await resourceTask.value.contents.count == 1)

    let toolCallTask = Task {
      try await connection.mcpServerToolCall(
        .init(
          arguments: .object(["path": .string("README.md")]),
          server: "filesystem",
          threadId: "thread-1",
          tool: "read_file"
        ))
    }
    guard case .mcpserverToolCallRequest(let toolCall) = try await nextRequest(peer) else {
      Issue.record("Expected mcpServer/tool/call generated request.")
      return
    }
    #expect(toolCall.method == .mcpserverToolCall)
    #expect(toolCall.params.arguments == .object(["path": .string("README.md")]))
    #expect(toolCall.params.server == "filesystem")
    #expect(toolCall.params.threadId == "thread-1")
    #expect(toolCall.params.tool == "read_file")
    peer.receiveLine(
      try responseLine(
        id: toolCall.id,
        result: Stable.McpServerToolCallResponse(
          content: [
            .object([
              "text": .string("# swift-codex"),
              "type": .string("text"),
            ])
          ],
          isError: false,
          structuredContent: .object(["ok": .bool(true)])
        )
      ))
    let toolCallResponse = try await toolCallTask.value
    #expect(toolCallResponse.isError == false)
    #expect(toolCallResponse.structuredContent == .object(["ok": .bool(true)]))

    await connection.close()
  }

  @Test("MCP events arrive on the notification stream")
  func mcpEventsArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startMCPReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(
      try mcpServerStartupStatusUpdatedNotificationLine(
        name: "filesystem",
        status: .ready
      ))

    guard
      case .mcpserverStartupStatusUpdatedNotification(let rawStatus) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw mcpServer/startupStatus/updated notification.")
      return
    }
    #expect(rawStatus.params.name == "filesystem")
    #expect(rawStatus.params.status == .ready)

    peer.receiveLine(
      try mcpServerOauthLoginCompletedNotificationLine(
        name: "github",
        success: true
      ))

    guard
      case .mcpserverOauthLoginCompletedNotification(let rawOauth) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw mcpServer/oauthLogin/completed notification.")
      return
    }
    #expect(rawOauth.params.name == "github")
    #expect(rawOauth.params.success == true)

    peer.receiveLine(
      try mcpToolCallProgressNotificationLine(
        itemId: "item-1",
        message: "Reading resource",
        threadId: "thread-1",
        turnId: "turn-1"
      ))

    guard
      case .itemMcpToolCallProgressNotification(let rawProgress) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw item/mcpToolCall/progress notification.")
      return
    }
    #expect(rawProgress.params.itemId == "item-1")
    #expect(rawProgress.params.message == "Reading resource")

    await connection.close()
  }

  @Test("MCP pending request fails when connection closes")
  func mcpPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startMCPReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.mcpServerResourceRead(
        .init(
          server: "filesystem",
          threadId: "thread-close",
          uri: "file:///slow.md"
        ))
    }

    guard case .mcpserverResourceReadRequest(let request) = try await nextRequest(peer) else {
      Issue.record("Expected mcpServer/resource/read generated request.")
      return
    }
    #expect(request.params.threadId == "thread-close")

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startMCPReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeMCPClient(peer: peer).start()
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

private func makeMCPClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_mcp_data_plane_tests",
        title: "swift-codex MCP Data-Plane Tests",
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
      userAgent: "Codex/swift-codex-mcp-data-plane-fixture"
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

private func mcpServerStartupStatusUpdatedNotificationLine(
  name: String,
  status: Stable.McpServerStartupState
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.mcpserverStartupStatusUpdatedNotification(
      .init(
        method: .mcpserverStartupStatusUpdated,
        params: .init(name: name, status: status)
      ))
  )
}

private func mcpServerOauthLoginCompletedNotificationLine(
  name: String,
  success: Bool
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.mcpserverOauthLoginCompletedNotification(
      .init(
        method: .mcpserverOauthLoginCompleted,
        params: .init(name: name, success: success)
      ))
  )
}

private func mcpToolCallProgressNotificationLine(
  itemId: String,
  message: String,
  threadId: String,
  turnId: String
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.itemMcpToolCallProgressNotification(
      .init(
        method: .itemMcpToolCallProgress,
        params: .init(
          itemId: itemId,
          message: message,
          threadId: threadId,
          turnId: turnId
        )
      ))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
