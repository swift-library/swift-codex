import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerProtocol

@Suite("CodexAppServer Initialize Contract")
struct CodexAppServerInitializeContractTests {
  @Test("Initialize request decodes through generated stable models")
  func initializeRequestDecodesThroughGeneratedStableModels() throws {
    let line = CodexAppServerBootstrapTranscripts.bootstrapSuccess.messages[0].line.rawObject
    let request = try CodexAppServerProtocolContractSupport.Initialize.decodeInitializeRequest(
      from: line
    )

    #expect(request.id == .requestidoption2(1))
    #expect(request.method == .initialize)
    #expect(request.params.clientInfo.name == "swift_codex_tests")
    #expect(request.params.clientInfo.title == "swift-codex AppServer Tests")
    #expect(request.params.clientInfo.version == "0.1.0")
    #expect(request.params.capabilities?.experimentalApi == false)
    #expect(request.params.capabilities?.optOutNotificationMethods == ["thread/started"])
  }

  @Test("Initialize response encodes through generated stable JSON-RPC response")
  func initializeResponseEncodesThroughGeneratedStableJSONRPCResponse() throws {
    let line = try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
      id: .requestidoption2(1),
      response: fixtureInitializeResponse()
    )

    let response = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self,
      from: line
    )

    #expect(response.id == .requestidoption2(1))
    #expect(
      response.result
        == .object([
          "codexHome": .string("/tmp/swift-codex/codex-home"),
          "platformFamily": .string("unix"),
          "platformOs": .string("macos"),
          "userAgent": .string("Codex/swift-codex-bootstrap-fixture"),
        ]))
  }

  @Test("Initialized notification decodes through generated stable client notification")
  func initializedNotificationDecodesThroughGeneratedStableModel() throws {
    let notification = try CodexAppServerProtocolContractSupport.Initialize
      .decodeInitializedNotification(
        from: #"{"method":"initialized"}"#
      )

    #expect(notification.method == .initialized)
  }

  @Test("Handshake session rejects request before initialize with generated error")
  func handshakeSessionRejectsRequestBeforeInitialize() throws {
    var session = CodexAppServerProtocolContractSupport.Initialize.Session(
      initializeResponse: fixtureInitializeResponse()
    )

    let result = try session.handleClientLine(
      #"{"id":2,"method":"config/read","params":{"includeLayers":false}}"#
    )

    guard case .requestBeforeInitializeError(let line) = result else {
      Issue.record("Expected request-before-initialize error.")
      return
    }

    let error = try decodeGenerated(CodexAppServerProtocol.Stable.JSONRPCError.self, from: line)
    #expect(error.id == .requestidoption2(2))
    #expect(
      error.error.code == CodexAppServerProtocolContractSupport.Initialize.invalidRequestErrorCode
    )
    #expect(error.error.message == "Not initialized")
    #expect(error.error.data == nil)
  }

  @Test("Handshake session accepts initialize and initialized then rejects double initialize")
  func handshakeSessionRejectsDoubleInitialize() throws {
    var session = CodexAppServerProtocolContractSupport.Initialize.Session(
      initializeResponse: fixtureInitializeResponse()
    )
    let firstInitializeLine = CodexAppServerBootstrapTranscripts.doubleInitializeFailure
      .messages[0]
      .line
      .rawObject
    let initializedLine = CodexAppServerBootstrapTranscripts.doubleInitializeFailure
      .messages[2]
      .line
      .rawObject
    let secondInitializeLine = CodexAppServerBootstrapTranscripts.doubleInitializeFailure
      .messages[3]
      .line
      .rawObject

    let firstResult = try session.handleClientLine(firstInitializeLine)
    guard case .initializeResponse(let request, let line) = firstResult else {
      Issue.record("Expected first initialize to return a response.")
      return
    }
    #expect(request.id == .requestidoption2(1))
    #expect(session.didInitialize)

    let response = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCResponse.self, from: line)
    #expect(response.id == .requestidoption2(1))

    let notificationResult = try session.handleClientLine(initializedLine)
    guard case .initializedNotification(let notification) = notificationResult else {
      Issue.record("Expected initialized notification to be accepted.")
      return
    }
    #expect(notification.method == .initialized)
    #expect(session.didReceiveInitializedNotification)

    let secondResult = try session.handleClientLine(secondInitializeLine)
    guard case .alreadyInitializedError(let errorLine) = secondResult else {
      Issue.record("Expected second initialize to return already-initialized error.")
      return
    }

    let error = try decodeGenerated(
      CodexAppServerProtocol.Stable.JSONRPCError.self,
      from: errorLine
    )
    #expect(error.id == .requestidoption2(3))
    #expect(
      error.error.code == CodexAppServerProtocolContractSupport.Initialize.invalidRequestErrorCode
    )
    #expect(error.error.message == "Already initialized")
    #expect(error.error.data == nil)
  }

}
private func fixtureInitializeResponse() -> CodexAppServerProtocol.Stable.InitializeResponse {
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
