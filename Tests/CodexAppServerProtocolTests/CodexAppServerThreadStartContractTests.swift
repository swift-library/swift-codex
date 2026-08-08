import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerProtocol

@Suite("CodexAppServer Thread Start Contract")
struct CodexAppServerThreadStartContractTests {
  @Test("Thread start request decodes through generated stable models")
  func threadStartRequestDecodesThroughGeneratedStableModels() throws {
    let request = try CodexAppServerProtocolContractSupport.ThreadStart.decodeThreadStartRequest(
      from: fixtureThreadStartRequestLine()
    )

    #expect(request.id == .requestidoption2(10))
    #expect(request.method == .threadStart)
    #expect(request.params.model == "gpt-5.1-codex")
    #expect(request.params.cwd == "/tmp/swift-codex/project")
    #expect(request.params.approvalPolicy == .never)
    #expect(request.params.sandbox == .workspaceWrite)
    #expect(request.params.personality == .pragmatic)
    #expect(request.params.sessionStartSource == .startup)
    #expect(request.params.ephemeral == true)
  }

  @Test("Thread start response encodes through generated stable JSON-RPC response")
  func threadStartResponseEncodesThroughGeneratedStableJSONRPCResponse() throws {
    let line = try CodexAppServerProtocolContractSupport.ThreadStart.encodeThreadStartResponseLine(
      id: .requestidoption2(10),
      response: fixtureThreadStartResponse()
    )

    let rpcResponse = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self,
      from: line
    )
    let response = try decodeGeneratedResult(
      CodexAppServerProtocol.Stable.ThreadStartResponse.self,
      from: rpcResponse
    )

    #expect(rpcResponse.id == .requestidoption2(10))
    #expect(response.thread.id == "thr_123")
    #expect(response.thread.status == .idle(.init(type: .idle)))
    #expect(response.model == "gpt-5.1-codex")
    #expect(response.modelProvider == "openai")
    #expect(response.cwd == "/tmp/swift-codex/project")
    #expect(response.approvalPolicy == .never)
    #expect(response.approvalsReviewer == .user)
  }

  @Test("Thread started notification encodes through generated stable server notification")
  func threadStartedNotificationEncodesThroughGeneratedStableServerNotification() throws {
    let line = try CodexAppServerProtocolContractSupport.ThreadStart
      .encodeThreadStartedNotificationLine(
        .init(thread: fixtureThread())
      )

    let notification = try decodeGenerated(
      CodexAppServerProtocol.Stable.ServerNotification.self,
      from: line
    )

    guard case .threadStartedNotification(let value) = notification else {
      Issue.record("Expected thread/started notification.")
      return
    }

    #expect(value.method == .threadStarted)
    #expect(value.params.thread.id == "thr_123")
    #expect(value.params.thread.status == .idle(.init(type: .idle)))
  }

  @Test("Thread start exchange returns response then optional notification after handshake")
  func threadStartExchangeReturnsResponseThenOptionalNotificationAfterHandshake() throws {
    var session = CodexAppServerProtocolContractSupport.Initialize.Session(
      initializeResponse: fixtureInitializeResponseForThreadStart()
    )
    _ = try session.handleClientLine(
      CodexAppServerBootstrapTranscripts.bootstrapSuccess.messages[0].line.rawObject
    )
    _ = try session.handleClientLine(
      CodexAppServerBootstrapTranscripts.bootstrapSuccess.messages[2].line.rawObject
    )

    let forwarded = try session.handleClientLine(fixtureThreadStartRequestLine())
    guard case .initializedRequest(let id, let method, let params) = forwarded else {
      Issue.record("Expected initialized thread/start request forwarding.")
      return
    }
    #expect(id == .requestidoption2(10))
    #expect(method == "thread/start")
    #expect(params != nil)

    let exchange = try CodexAppServerProtocolContractSupport.ThreadStart.makeThreadStartExchange(
      requestLine: fixtureThreadStartRequestLine(),
      response: fixtureThreadStartResponse()
    )

    #expect(exchange.request.id == .requestidoption2(10))
    #expect(exchange.notificationLine != nil)

    let response = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self,
      from: exchange.responseLine
    )
    #expect(response.id == .requestidoption2(10))
  }

  @Test("Thread start notification routing respects exact opt-out method")
  func threadStartNotificationRoutingRespectsExactOptOutMethod() throws {
    let emitted = try CodexAppServerProtocolContractSupport.ThreadStart.makeThreadStartExchange(
      requestLine: fixtureThreadStartRequestLine(),
      response: fixtureThreadStartResponse(),
      notificationOptOutMethods: ["thread/started"]
    )
    let notEmitted = try CodexAppServerProtocolContractSupport.ThreadStart.makeThreadStartExchange(
      requestLine: fixtureThreadStartRequestLine(),
      response: fixtureThreadStartResponse(),
      notificationOptOutMethods: ["thread"]
    )

    #expect(emitted.notificationLine == nil)
    #expect(notEmitted.notificationLine != nil)
  }

}
private func fixtureThreadStartRequestLine() -> String {
  """
  {"id":10,"method":"thread/start","params":{"approvalPolicy":"never","cwd":"/tmp/swift-codex/project","ephemeral":true,"model":"gpt-5.1-codex","personality":"pragmatic","sandbox":"workspace-write","sessionStartSource":"startup"}}
  """
}

private func fixtureThreadStartResponse() -> CodexAppServerProtocol.Stable.ThreadStartResponse {
  CodexAppServerProtocol.Stable.ThreadStartResponse(
    approvalPolicy: .never,
    approvalsReviewer: .user,
    cwd: "/tmp/swift-codex/project",
    instructionSources: [],
    model: "gpt-5.1-codex",
    modelProvider: "openai",
    reasoningEffort: nil,
    sandbox: .readonly(.init(networkAccess: false, type: .readonly)),
    serviceTier: nil,
    thread: fixtureThread()
  )
}

private func fixtureThread() -> CodexAppServerProtocol.Stable.Thread {
  CodexAppServerProtocol.Stable.Thread(
    agentNickname: nil,
    agentRole: nil,
    cliVersion: "codex-0.0.0",
    createdAt: 1_730_910_000,
    cwd: "/tmp/swift-codex/project",
    ephemeral: true,
    forkedFromId: nil,
    gitInfo: nil,
    id: "thr_123",
    modelProvider: "openai",
    name: nil,
    path: nil,
    preview: "",
    sessionId: "session-123",
    source: .appserver,
    status: .idle(.init(type: .idle)),
    turns: [],
    updatedAt: 1_730_910_000
  )
}

private func fixtureInitializeResponseForThreadStart()
  -> CodexAppServerProtocol.Stable.InitializeResponse
{
  CodexAppServerProtocol.Stable.InitializeResponse(
    codexHome: "/tmp/swift-codex/codex-home",
    platformFamily: "unix",
    platformOs: "macos",
    userAgent: "Codex/swift-codex-bootstrap-fixture"
  )
}

private func decodeGenerated<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(line.utf8))
}

private func decodeGeneratedResult<T: Decodable>(
  _ type: T.Type,
  from response: CodexAppServerProtocol.Stable.JSONRPCResponse
) throws -> T {
  let data = try JSONEncoder().encode(response.result)
  return try JSONDecoder().decode(T.self, from: data)
}
