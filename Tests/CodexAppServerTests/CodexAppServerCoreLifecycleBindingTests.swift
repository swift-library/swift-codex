import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Core Lifecycle Binding")
struct CodexAppServerCoreLifecycleBindingTests {
  @Test("Core lifecycle binding sends thread/start and returns generated response")
  func coreLifecycleBindingSendsThreadStartAndReturnsGeneratedResponse() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.threadStart(
        Stable.ThreadStartParams(
          approvalPolicy: .never,
          cwd: "/tmp/swift-codex/project",
          model: "gpt-5.1-codex",
          sandbox: .workspaceWrite,
          sessionStartSource: .startup
        ))
    }

    let requestLine = await peer.nextSentLine()
    let clientRequest = try decode(Stable.ClientRequest.self, from: requestLine)
    guard case .threadStartRequest(let request) = clientRequest else {
      Issue.record("Expected thread/start generated request.")
      return
    }

    #expect(request.method == .threadStart)
    #expect(request.params.cwd == "/tmp/swift-codex/project")
    #expect(request.params.approvalPolicy == .never)
    #expect(request.params.sandbox == .workspaceWrite)

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: threadStartResponse(threadID: "thr_start")
      ))

    let response = try await requestTask.value
    #expect(response.thread.id == "thr_start")
    #expect(response.model == "gpt-5.1-codex")

    await connection.close()
  }

  @Test("Core lifecycle binding sends thread/resume and returns generated response")
  func coreLifecycleBindingSendsThreadResumeAndReturnsGeneratedResponse() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.threadResume(
        Stable.ThreadResumeParams(
          cwd: "/tmp/swift-codex/project",
          model: "gpt-5.1-codex",
          threadId: "thr_existing"
        ))
    }

    let requestLine = await peer.nextSentLine()
    let clientRequest = try decode(Stable.ClientRequest.self, from: requestLine)
    guard case .threadResumeRequest(let request) = clientRequest else {
      Issue.record("Expected thread/resume generated request.")
      return
    }

    #expect(request.method == .threadResume)
    #expect(request.params.threadId == "thr_existing")
    #expect(request.params.cwd == "/tmp/swift-codex/project")

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: threadResumeResponse(threadID: "thr_existing")
      ))

    let response = try await requestTask.value
    #expect(response.thread.id == "thr_existing")
    #expect(response.thread.source == .appserver)

    await connection.close()
  }

  @Test("Core lifecycle binding sends turn/start and returns generated response")
  func coreLifecycleBindingSendsTurnStartAndReturnsGeneratedResponse() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.turnStart(
        Stable.TurnStartParams(
          effort: "medium",
          input: [
            .text(.init(text: "Run tests", type: .text))
          ],
          model: "gpt-5.1-codex",
          threadId: "thr_existing"
        ))
    }

    let requestLine = await peer.nextSentLine()
    let clientRequest = try decode(Stable.ClientRequest.self, from: requestLine)
    guard case .turnStartRequest(let request) = clientRequest else {
      Issue.record("Expected turn/start generated request.")
      return
    }

    #expect(request.method == .turnStart)
    #expect(request.params.threadId == "thr_existing")
    #expect(request.params.effort == "medium")

    guard case .text(let input) = request.params.input.first else {
      Issue.record("Expected text turn input.")
      return
    }
    #expect(input.text == "Run tests")

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: Stable.TurnStartResponse(turn: turn(id: "turn_start"))
      ))

    let response = try await requestTask.value
    #expect(response.turn.id == "turn_start")
    #expect(response.turn.status == .inprogress)

    await connection.close()
  }

  @Test("Core lifecycle binding keeps responses separate from notification stream")
  func coreLifecycleBindingKeepsResponsesSeparateFromNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)
    var notifications = connection.notifications.makeAsyncIterator()

    let requestTask = Task {
      try await connection.threadStart(
        Stable.ThreadStartParams(
          cwd: "/tmp/swift-codex/project",
          model: "gpt-5.1-codex"
        ))
    }

    let clientRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .threadStartRequest(let request) = clientRequest else {
      Issue.record("Expected thread/start generated request.")
      return
    }

    peer.receiveLine(
      try responseLine(
        id: request.id,
        result: threadStartResponse(threadID: "thr_notified")
      ))
    peer.receiveLine(try threadStartedNotificationLine(threadID: "thr_notified"))

    let response = try await requestTask.value
    #expect(response.thread.id == "thr_notified")

    guard case .threadStartedNotification(let notification) = try await notifications.next() else {
      Issue.record("Expected thread/started notification on notification stream.")
      return
    }
    #expect(notification.params.thread.id == "thr_notified")

    await connection.close()
  }

  @Test("Core lifecycle binding maps JSON-RPC errors through connection semantics")
  func coreLifecycleBindingMapsJSONRPCErrorsThroughConnectionSemantics() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.turnStart(
        Stable.TurnStartParams(
          input: [
            .text(.init(text: "Run tests", type: .text))
          ],
          threadId: "thr_existing"
        ))
    }

    let clientRequest = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    guard case .turnStartRequest(let request) = clientRequest else {
      Issue.record("Expected turn/start generated request.")
      return
    }

    peer.receiveLine(
      try CodexAppServerConnectionFoundation.encodeLine(
        Stable.JSONRPCError(
          error: .init(
            code: -32602,
            data: .object(["reason": .string("bad turn")]),
            message: "Invalid params"
          ),
          id: request.id
        )
      ))

    do {
      _ = try await requestTask.value
      Issue.record("Expected JSON-RPC error.")
    } catch let error as CodexAppServerClientError {
      #expect(
        error
          == .jsonRPCError(
            code: -32602,
            message: "Invalid params",
            data: .object(["reason": .string("bad turn")])
          ))
    }

    await connection.close()
  }

  @Test("Core lifecycle binding cancellation does not corrupt notification stream")
  func coreLifecycleBindingCancellationDoesNotCorruptNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startLifecycleReadyConnection(peer: peer)
    var notifications = connection.notifications.makeAsyncIterator()

    let requestTask = Task {
      try await connection.threadResume(Stable.ThreadResumeParams(threadId: "thr_cancel"))
    }

    _ = try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
    requestTask.cancel()

    do {
      _ = try await requestTask.value
      Issue.record("Expected request cancellation.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .requestCancelled)
    } catch is CancellationError {
    }

    peer.receiveLine(try warningNotificationLine("still-open"))

    guard case .warningnotification(let notification) = try await notifications.next() else {
      Issue.record("Expected warning notification after cancelled request.")
      return
    }
    #expect(notification.params.message == "still-open")

    await connection.close()
  }

}
private func startLifecycleReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeLifecycleClient(peer: peer).start()
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

private func makeLifecycleClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_lifecycle_tests",
        title: "swift-codex Lifecycle Tests",
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
      userAgent: "Codex/swift-codex-lifecycle-fixture"
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

private func threadStartResponse(threadID: String) -> Stable.ThreadStartResponse {
  Stable.ThreadStartResponse(
    approvalPolicy: .never,
    approvalsReviewer: .user,
    cwd: "/tmp/swift-codex/project",
    instructionSources: [],
    model: "gpt-5.1-codex",
    modelProvider: "openai",
    sandbox: .readonly(.init(networkAccess: false, type: .readonly)),
    thread: thread(id: threadID)
  )
}

private func threadResumeResponse(threadID: String) -> Stable.ThreadResumeResponse {
  Stable.ThreadResumeResponse(
    approvalPolicy: .never,
    approvalsReviewer: .user,
    cwd: "/tmp/swift-codex/project",
    instructionSources: [],
    model: "gpt-5.1-codex",
    modelProvider: "openai",
    sandbox: .readonly(.init(networkAccess: false, type: .readonly)),
    thread: thread(id: threadID)
  )
}

private func threadStartedNotificationLine(threadID: String) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadStartedNotification(
      .init(method: .threadStarted, params: .init(thread: thread(id: threadID)))
    )
  )
}

private func warningNotificationLine(_ message: String) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.warningnotification(
      .init(method: .warning, params: .init(message: message, threadId: nil))
    )
  )
}

private func thread(id: String) -> Stable.Thread {
  Stable.Thread(
    cliVersion: "codex-0.0.0",
    createdAt: 1_730_910_000,
    cwd: "/tmp/swift-codex/project",
    ephemeral: true,
    id: id,
    modelProvider: "openai",
    preview: "",
    sessionId: "session-\(id)",
    source: .appserver,
    status: .idle(.init(type: .idle)),
    turns: [],
    updatedAt: 1_730_910_000
  )
}

private func turn(id: String) -> Stable.Turn {
  Stable.Turn(
    id: id,
    items: [],
    status: .inprogress
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
