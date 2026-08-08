import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Command Exec Binding")
struct CodexAppServerCommandExecBindingTests {
  @Test("Command exec binding sends command/exec and returns generated response")
  func commandExecBindingSendsCommandExecAndReturnsGeneratedResponse() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startCommandExecReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.commandExec(
        .init(
          command: ["bash", "-lc", "echo hi"],
          cwd: "/tmp/swift-codex/project",
          processId: "proc-1",
          size: .init(cols: 80, rows: 24),
          streamStdin: true,
          streamStdoutStderr: true,
          tty: true
        ))
    }

    let clientRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .commandExecRequest(let request) = clientRequest else {
      Issue.record("Expected command/exec generated request.")
      return
    }

    #expect(request.method == .commandExec)
    #expect(request.params.command == ["bash", "-lc", "echo hi"])
    #expect(request.params.processId == "proc-1")
    #expect(request.params.streamStdin == true)
    #expect(request.params.streamStdoutStderr == true)
    #expect(request.params.tty == true)
    #expect(request.params.size == .init(cols: 80, rows: 24))

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: Stable.CommandExecResponse(exitCode: 0, stderr: "", stdout: "hi\n")
      ))

    let response = try await requestTask.value
    #expect(response.exitCode == 0)
    #expect(response.stdout == "hi\n")
    #expect(response.stderr.isEmpty)

    await connection.close()
  }

  @Test("Command exec binding sends write terminate and resize controls")
  func commandExecBindingSendsWriteTerminateAndResizeControls() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startCommandExecReadyConnection(peer: peer)

    let writeTask = Task {
      try await connection.commandExecWrite(
        .init(
          closeStdin: false,
          deltaBase64: "aW5wdXQ=",
          processId: "proc-1"
        ))
    }
    let writeRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .commandExecWriteRequest(let write) = writeRequest else {
      Issue.record("Expected command/exec/write generated request.")
      return
    }
    #expect(write.method == .commandExecWrite)
    #expect(write.params.processId == "proc-1")
    #expect(write.params.deltaBase64 == "aW5wdXQ=")
    peer.receiveLine(try responseLine(id: write.id, result: Stable.CommandExecWriteResponse()))
    #expect(try await writeTask.value.isEmpty)

    let resizeTask = Task {
      try await connection.commandExecResize(
        .init(
          processId: "proc-1",
          size: .init(cols: 120, rows: 40)
        ))
    }
    let resizeRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .commandExecResizeRequest(let resize) = resizeRequest else {
      Issue.record("Expected command/exec/resize generated request.")
      return
    }
    #expect(resize.method == .commandExecResize)
    #expect(resize.params.size == .init(cols: 120, rows: 40))
    peer.receiveLine(try responseLine(id: resize.id, result: Stable.CommandExecResizeResponse()))
    #expect(try await resizeTask.value.isEmpty)

    let terminateTask = Task {
      try await connection.commandExecTerminate(.init(processId: "proc-1"))
    }
    let terminateRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .commandExecTerminateRequest(let terminate) = terminateRequest else {
      Issue.record("Expected command/exec/terminate generated request.")
      return
    }
    #expect(terminate.method == .commandExecTerminate)
    #expect(terminate.params.processId == "proc-1")
    peer.receiveLine(
      try responseLine(id: terminate.id, result: Stable.CommandExecTerminateResponse()))
    #expect(try await terminateTask.value.isEmpty)

    await connection.close()
  }

  @Test("Command exec output deltas arrive on the notification stream")
  func commandExecOutputDeltasArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startCommandExecReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(
      try commandExecOutputDeltaLine(
        processId: "proc-1",
        deltaBase64: "aGk=",
        stream: .stdout
      ))

    guard case .commandExecOutputDeltaNotification(let raw) = try await rawNotifications.next()
    else {
      Issue.record("Expected raw command/exec/outputDelta notification.")
      return
    }
    #expect(raw.params.processId == "proc-1")
    #expect(raw.params.deltaBase64 == "aGk=")
    #expect(raw.params.stream == .stdout)
    #expect(raw.params.capReached == false)

    await connection.close()
  }

  @Test("Command exec pending request fails when connection closes")
  func commandExecPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startCommandExecReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.commandExec(
        .init(
          command: ["sleep", "10"],
          processId: "proc-close",
          streamStdoutStderr: true
        ))
    }

    let clientRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .commandExecRequest(let request) = clientRequest else {
      Issue.record("Expected command/exec generated request.")
      return
    }
    #expect(request.params.processId == "proc-close")

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startCommandExecReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeCommandExecClient(peer: peer).start()
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

private func makeCommandExecClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_command_exec_tests",
        title: "swift-codex Command Exec Tests",
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
      userAgent: "Codex/swift-codex-command-exec-fixture"
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

private func commandExecOutputDeltaLine(
  processId: String,
  deltaBase64: String,
  stream: Stable.CommandExecOutputStream
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.commandExecOutputDeltaNotification(
      .init(
        method: .commandExecOutputDelta,
        params: .init(
          capReached: false,
          deltaBase64: deltaBase64,
          processId: processId,
          stream: stream
        )
      ))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
