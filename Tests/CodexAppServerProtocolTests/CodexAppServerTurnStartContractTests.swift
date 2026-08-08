import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerProtocol

@Suite("CodexAppServer Turn Start Contract")
struct CodexAppServerTurnStartContractTests {
  @Test("Turn start request decodes through generated stable models")
  func turnStartRequestDecodesThroughGeneratedStableModels() throws {
    let request = try CodexAppServerProtocolContractSupport.TurnStart.decodeTurnStartRequest(
      from: fixtureTurnStartRequestLine()
    )

    #expect(request.id == .requestidoption2(30))
    #expect(request.method == .turnStart)
    #expect(request.params.threadId == "thr_123")
    #expect(request.params.model == "gpt-5.1-codex")
    #expect(request.params.effort == "medium")
    #expect(request.params.outputSchema != nil)

    guard case .text(let textInput) = request.params.input.first else {
      Issue.record("Expected first turn input to be text.")
      return
    }
    #expect(textInput.type == .text)
    #expect(textInput.text == "Run tests")
  }

  @Test("Turn start response encodes through generated stable JSON-RPC response")
  func turnStartResponseEncodesThroughGeneratedStableJSONRPCResponse() throws {
    let line = try CodexAppServerProtocolContractSupport.TurnStart.encodeTurnStartResponseLine(
      id: .requestidoption2(30),
      response: fixtureTurnStartResponse()
    )

    let rpcResponse = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self,
      from: line
    )
    let response = try decodeGeneratedResult(
      CodexAppServerProtocol.Stable.TurnStartResponse.self,
      from: rpcResponse
    )

    #expect(rpcResponse.id == .requestidoption2(30))
    #expect(response.turn.id == "turn_456")
    #expect(response.turn.status == .inprogress)
    #expect(response.turn.items.isEmpty)
    #expect(response.turn.error == nil)
  }

  @Test("Turn started notification encodes through generated stable server notification")
  func turnStartedNotificationEncodesThroughGeneratedStableServerNotification() throws {
    let line = try CodexAppServerProtocolContractSupport.TurnStart
      .encodeTurnStartedNotificationLine(
        .init(threadId: "thr_123", turn: fixtureTurn())
      )

    let notification = try decodeGenerated(
      CodexAppServerProtocol.Stable.ServerNotification.self,
      from: line
    )

    guard case .turnStartedNotification(let value) = notification else {
      Issue.record("Expected turn/started notification.")
      return
    }

    #expect(value.method == .turnStarted)
    #expect(value.params.threadId == "thr_123")
    #expect(value.params.turn.id == "turn_456")
    #expect(value.params.turn.status == .inprogress)
  }

  @Test("Turn start exchange returns response then optional notification after handshake")
  func turnStartExchangeReturnsResponseThenOptionalNotificationAfterHandshake() throws {
    var session = CodexAppServerProtocolContractSupport.Initialize.Session(
      initializeResponse: fixtureInitializeResponseForTurnStart()
    )
    _ = try session.handleClientLine(
      CodexAppServerBootstrapTranscripts.bootstrapSuccess.messages[0].line.rawObject
    )
    _ = try session.handleClientLine(
      CodexAppServerBootstrapTranscripts.bootstrapSuccess.messages[2].line.rawObject
    )

    let forwarded = try session.handleClientLine(fixtureTurnStartRequestLine())
    guard case .initializedRequest(let id, let method, let params) = forwarded else {
      Issue.record("Expected initialized turn/start request forwarding.")
      return
    }
    #expect(id == .requestidoption2(30))
    #expect(method == "turn/start")
    #expect(params != nil)

    let exchange = try CodexAppServerProtocolContractSupport.TurnStart.makeTurnStartExchange(
      requestLine: fixtureTurnStartRequestLine(),
      response: fixtureTurnStartResponse()
    )

    #expect(exchange.request.id == .requestidoption2(30))
    #expect(exchange.request.params.threadId == "thr_123")
    #expect(exchange.notificationLine != nil)

    let response = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self,
      from: exchange.responseLine
    )
    #expect(response.id == .requestidoption2(30))
  }

  @Test("Turn started notification routing respects exact opt-out method")
  func turnStartedNotificationRoutingRespectsExactOptOutMethod() throws {
    let emitted = try CodexAppServerProtocolContractSupport.TurnStart.makeTurnStartExchange(
      requestLine: fixtureTurnStartRequestLine(),
      response: fixtureTurnStartResponse(),
      notificationOptOutMethods: ["turn/started"]
    )
    let notEmitted = try CodexAppServerProtocolContractSupport.TurnStart.makeTurnStartExchange(
      requestLine: fixtureTurnStartRequestLine(),
      response: fixtureTurnStartResponse(),
      notificationOptOutMethods: ["turn"]
    )

    #expect(emitted.notificationLine == nil)
    #expect(notEmitted.notificationLine != nil)
  }

}
private func fixtureTurnStartRequestLine() -> String {
  """
  {"id":30,"method":"turn/start","params":{"effort":"medium","input":[{"text":"Run tests","type":"text"}],"model":"gpt-5.1-codex","outputSchema":{"properties":{"answer":{"type":"string"}},"required":["answer"],"type":"object"},"threadId":"thr_123"}}
  """
}

private func fixtureTurnStartResponse() -> CodexAppServerProtocol.Stable.TurnStartResponse {
  CodexAppServerProtocol.Stable.TurnStartResponse(turn: fixtureTurn())
}

private func fixtureTurn() -> CodexAppServerProtocol.Stable.Turn {
  CodexAppServerProtocol.Stable.Turn(
    completedAt: nil,
    durationMs: nil,
    error: nil,
    id: "turn_456",
    items: [],
    startedAt: nil,
    status: .inprogress
  )
}

private func fixtureInitializeResponseForTurnStart()
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
