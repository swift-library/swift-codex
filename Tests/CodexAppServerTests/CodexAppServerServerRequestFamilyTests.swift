import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Server Request Family")
struct CodexAppServerServerRequestFamilyTests {
  @Test("Typed server request stream routes all stable server-request families")
  func typedServerRequestStreamRoutesAllStableServerRequestFamilies() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startServerRequestReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    for request in stableServerRequestFixtures() {
      peer.receiveLine(try CodexAppServerConnectionFoundation.encodeLine(request))
    }

    guard case .commandExecutionApproval(let command) = try await requests.next() else {
      Issue.record("Expected command execution approval request.")
      return
    }
    #expect(command.id == .requestidoption1("command-approval"))
    #expect(command.params.itemId == "item-command")

    guard case .fileChangeApproval(let fileChange) = try await requests.next() else {
      Issue.record("Expected file change approval request.")
      return
    }
    #expect(fileChange.id == .requestidoption1("file-change"))
    #expect(fileChange.params.itemId == "item-file")

    guard case .toolRequestUserInput(let userInput) = try await requests.next() else {
      Issue.record("Expected tool request-user-input request.")
      return
    }
    #expect(userInput.id == .requestidoption1("tool-input"))
    #expect(userInput.params.questions.first?.id == "choice")

    guard case .mcpServerElicitation(let elicitation) = try await requests.next() else {
      Issue.record("Expected MCP elicitation request.")
      return
    }
    #expect(elicitation.id == .requestidoption1("mcp-elicit"))

    guard case .permissionsApproval(let permissions) = try await requests.next() else {
      Issue.record("Expected permissions approval request.")
      return
    }
    #expect(permissions.id == .requestidoption1("permissions"))
    #expect(permissions.params.itemId == "item-permissions")

    guard case .dynamicToolCall(let toolCall) = try await requests.next() else {
      Issue.record("Expected dynamic tool call request.")
      return
    }
    #expect(toolCall.id == .requestidoption1("dynamic-tool"))
    #expect(toolCall.params.tool == "dynamic-tool")

    guard case .chatgptAuthTokensRefresh(let authRefresh) = try await requests.next() else {
      Issue.record("Expected ChatGPT auth tokens refresh request.")
      return
    }
    #expect(authRefresh.id == .requestidoption1("auth-refresh"))
    #expect(authRefresh.params.reason == .unauthorized)

    guard case .applyPatchApproval(let applyPatch) = try await requests.next() else {
      Issue.record("Expected apply patch approval request.")
      return
    }
    #expect(applyPatch.id == .requestidoption1("apply-patch"))
    #expect(applyPatch.params.callId == "apply-call")

    guard case .execCommandApproval(let execCommand) = try await requests.next() else {
      Issue.record("Expected exec command approval request.")
      return
    }
    #expect(execCommand.id == .requestidoption1("exec-command"))
    #expect(execCommand.params.command == ["git", "status"])

    guard case .attestationGenerate(let attestation) = try await requests.next() else {
      Issue.record("Expected attestation generation request.")
      return
    }
    #expect(attestation.id == .requestidoption1("attestation"))

    await connection.close()
  }

  @Test("Typed server request stream preserves the request identifier")
  func typedServerRequestStreamPreservesRequestIdentifier() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startServerRequestReadyConnection(peer: peer)
    var typedRequests = connection.typedServerRequests.makeAsyncIterator()
    let request = authRefreshServerRequest(id: .requestidoption1("auth-both"))

    peer.receiveLine(try CodexAppServerConnectionFoundation.encodeLine(request))

    guard case .chatgptAuthTokensRefresh(let typed) = try await typedRequests.next() else {
      Issue.record("Expected typed auth refresh request.")
      return
    }
    #expect(typed.id == .requestidoption1("auth-both"))

    await connection.close()
  }

  @Test("Typed server request resolve encodes the matching generated response")
  func typedServerRequestResolveEncodesMatchingGeneratedResponse() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startServerRequestReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        authRefreshServerRequest(id: .requestidoption1("auth-resolve"))
      ))

    guard case .chatgptAuthTokensRefresh(let request) = try await requests.next() else {
      Issue.record("Expected auth refresh request.")
      return
    }

    try await connection.resolveServerRequest(
      request,
      with: Stable.ChatgptAuthTokensRefreshResponse(
        accessToken: "access-token",
        chatgptAccountId: "account-id",
        chatgptPlanType: "plus"
      )
    )

    let response = try decode(Stable.JSONRPCResponse.self, from: await peer.nextSentLine())
    #expect(response.id == .requestidoption1("auth-resolve"))
    #expect(
      response.result
        == .object([
          "accessToken": .string("access-token"),
          "chatgptAccountId": .string("account-id"),
          "chatgptPlanType": .string("plus"),
        ]))

    await connection.close()
  }

  @Test("Typed server request reject encodes JSON-RPC error")
  func typedServerRequestRejectEncodesJSONRPCError() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startServerRequestReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        dynamicToolCallServerRequest(id: .requestidoption1("tool-reject"))
      ))

    guard case .dynamicToolCall(let request) = try await requests.next() else {
      Issue.record("Expected dynamic tool call request.")
      return
    }

    try await connection.rejectServerRequest(
      request,
      code: -32603,
      message: "tool declined",
      data: .object(["reason": .string("test")])
    )

    let error = try decode(Stable.JSONRPCError.self, from: await peer.nextSentLine())
    #expect(error.id == .requestidoption1("tool-reject"))
    #expect(error.error.code == -32603)
    #expect(error.error.message == "tool declined")
    #expect(error.error.data == .object(["reason": .string("test")]))

    await connection.close()
  }

  @Test("Typed server request cannot be completed twice")
  func typedServerRequestCannotBeCompletedTwice() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startServerRequestReadyConnection(peer: peer)
    var requests = connection.typedServerRequests.makeAsyncIterator()

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        applyPatchApprovalServerRequest(id: .requestidoption1("apply-once"))
      ))

    guard case .applyPatchApproval(let request) = try await requests.next() else {
      Issue.record("Expected apply patch approval request.")
      return
    }

    try await connection.resolveServerRequest(
      request,
      with: Stable.ApplyPatchApprovalResponse(decision: .approved)
    )
    _ = await peer.nextSentLine()

    do {
      try await connection.resolveServerRequest(
        request,
        with: Stable.ApplyPatchApprovalResponse(
          decision: .deniedreviewdecision(
            .init(denied: .init(rejection: "Already resolved"))))
      )
      Issue.record("Expected already-completed failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .serverRequestAlreadyCompleted(id: .requestidoption1("apply-once")))
    }

    await connection.close()
  }

}
private func startServerRequestReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeServerRequestClient(peer: peer).start()
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

private func makeServerRequestClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_server_request_tests",
        title: "swift-codex Server Request Tests",
        version: "0.1.0"
      )
    ),
    transportFactory: {
      peer
    }
  )
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: .init(
      codexHome: "/tmp/swift-codex/codex-home",
      platformFamily: "unix",
      platformOs: "macos",
      userAgent: "Codex/swift-codex-server-request-fixture"
    )
  )
}

private func stableServerRequestFixtures() -> [Stable.ServerRequest] {
  [
    .itemCommandExecutionRequestApprovalRequest(
      .init(
        id: .requestidoption1("command-approval"),
        method: .itemCommandExecutionRequestApproval,
        params: .init(
          itemId: "item-command",
          startedAtMs: 1,
          threadId: "thr_123",
          turnId: "turn_123"
        )
      )),
    .itemFileChangeRequestApprovalRequest(
      .init(
        id: .requestidoption1("file-change"),
        method: .itemFileChangeRequestApproval,
        params: .init(
          itemId: "item-file",
          startedAtMs: 1,
          threadId: "thr_123",
          turnId: "turn_123"
        )
      )),
    .itemToolRequestUserInputRequest(
      .init(
        id: .requestidoption1("tool-input"),
        method: .itemToolRequestUserInput,
        params: .init(
          isBlocking: true,
          itemId: "item-input",
          questions: [
            .init(header: "Choice", id: "choice", question: "Pick one")
          ],
          threadId: "thr_123",
          turnId: "turn_123"
        )
      )),
    .mcpserverElicitationRequestRequest(
      .init(
        id: .requestidoption1("mcp-elicit"),
        method: .mcpserverElicitationRequest,
        params: .mcpserverelicitationrequestparamsoption3(
          .init(
            elicitationId: "elicit-1",
            message: "Open authorization page",
            mode: .url,
            url: "https://example.com/auth"
          ))
      )),
    .itemPermissionsRequestApprovalRequest(
      .init(
        id: .requestidoption1("permissions"),
        method: .itemPermissionsRequestApproval,
        params: .init(
          cwd: "/tmp/swift-codex/project",
          itemId: "item-permissions",
          permissions: .init(),
          startedAtMs: 1,
          threadId: "thr_123",
          turnId: "turn_123"
        )
      )),
    dynamicToolCallServerRequest(id: .requestidoption1("dynamic-tool")),
    authRefreshServerRequest(id: .requestidoption1("auth-refresh")),
    applyPatchApprovalServerRequest(id: .requestidoption1("apply-patch")),
    .execcommandapprovalrequest(
      .init(
        id: .requestidoption1("exec-command"),
        method: .execcommandapproval,
        params: .init(
          callId: "exec-call",
          command: ["git", "status"],
          conversationId: "thr_123",
          cwd: "/tmp/swift-codex/project",
          parsedCmd: []
        )
      )),
    .attestationGenerateRequest(
      .init(
        id: .requestidoption1("attestation"),
        method: .attestationGenerate,
        params: .init()
      )),
  ]
}

private func dynamicToolCallServerRequest(id: Stable.RequestId) -> Stable.ServerRequest {
  .itemToolCallRequest(
    .init(
      id: id,
      method: .itemToolCall,
      params: .init(
        arguments: .object(["prompt": .string("hello")]),
        callId: "tool-call",
        threadId: "thr_123",
        tool: "dynamic-tool",
        turnId: "turn_123"
      )
    ))
}

private func authRefreshServerRequest(id: Stable.RequestId) -> Stable.ServerRequest {
  .accountChatgptAuthTokensRefreshRequest(
    .init(
      id: id,
      method: .accountChatgptAuthTokensRefresh,
      params: .init(previousAccountId: nil, reason: .unauthorized)
    ))
}

private func applyPatchApprovalServerRequest(id: Stable.RequestId) -> Stable.ServerRequest {
  .applypatchapprovalrequest(
    .init(
      id: id,
      method: .applypatchapproval,
      params: .init(
        callId: "apply-call",
        conversationId: "thr_123",
        fileChanges: [:]
      )
    ))
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
