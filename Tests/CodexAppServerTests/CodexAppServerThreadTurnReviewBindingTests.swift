import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Thread Turn Review Binding")
struct CodexAppServerThreadTurnReviewBindingTests {
  @Test("Thread follow-on binding sends stable thread history requests")
  func threadFollowOnBindingSendsStableThreadHistoryRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startThreadTurnReviewReadyConnection(peer: peer)

    let forkTask = Task {
      try await connection.threadFork(
        .init(
          cwd: "/tmp/swift-codex/project",
          model: "gpt-5.1-codex",
          threadId: "thr_source"
        ))
    }
    guard case .threadForkRequest(let fork) = try await nextRequest(peer) else {
      Issue.record("Expected thread/fork generated request.")
      return
    }
    #expect(fork.method == .threadFork)
    #expect(fork.params.threadId == "thr_source")
    peer.receiveLine(
      try responseLine(
        id: fork.id,
        result: threadForkResponse(threadID: "thr_fork")
      ))
    #expect(try await forkTask.value.thread.id == "thr_fork")

    let listTask = Task {
      try await connection.threadList(
        .init(
          archived: false,
          limit: 10,
          sortDirection: .desc,
          sortKey: .updatedAt
        ))
    }
    guard case .threadListRequest(let list) = try await nextRequest(peer) else {
      Issue.record("Expected thread/list generated request.")
      return
    }
    #expect(list.method == .threadList)
    #expect(list.params.limit == 10)
    #expect(list.params.sortKey == .updatedAt)
    peer.receiveLine(
      try responseLine(
        id: list.id,
        result: Stable.ThreadListResponse(
          data: [thread(id: "thr_list")],
          nextCursor: "cursor-next"
        )
      ))
    let listResponse = try await listTask.value
    #expect(listResponse.data.map(\.id) == ["thr_list"])
    #expect(listResponse.nextCursor == "cursor-next")

    let readTask = Task {
      try await connection.threadRead(.init(includeTurns: true, threadId: "thr_list"))
    }
    guard case .threadReadRequest(let read) = try await nextRequest(peer) else {
      Issue.record("Expected thread/read generated request.")
      return
    }
    #expect(read.method == .threadRead)
    #expect(read.params.includeTurns == true)
    peer.receiveLine(
      try responseLine(
        id: read.id,
        result: Stable.ThreadReadResponse(thread: thread(id: "thr_list"))
      ))
    #expect(try await readTask.value.thread.id == "thr_list")

    let loadedListTask = Task {
      try await connection.threadLoadedList(.init(cursor: "cursor-1", limit: 2))
    }
    guard case .threadLoadedListRequest(let loadedList) = try await nextRequest(peer) else {
      Issue.record("Expected thread/loaded/list generated request.")
      return
    }
    #expect(loadedList.method == .threadLoadedList)
    #expect(loadedList.params.cursor == "cursor-1")
    peer.receiveLine(
      try responseLine(
        id: loadedList.id,
        result: Stable.ThreadLoadedListResponse(data: ["thr_loaded"])
      ))
    #expect(try await loadedListTask.value.data == ["thr_loaded"])

    let archiveTask = Task {
      try await connection.threadArchive(.init(threadId: "thr_list"))
    }
    guard case .threadArchiveRequest(let archive) = try await nextRequest(peer) else {
      Issue.record("Expected thread/archive generated request.")
      return
    }
    #expect(archive.method == .threadArchive)
    #expect(archive.params.threadId == "thr_list")
    peer.receiveLine(try responseLine(id: archive.id, result: Stable.ThreadArchiveResponse()))
    #expect(try await archiveTask.value.isEmpty)

    let unarchiveTask = Task {
      try await connection.threadUnarchive(.init(threadId: "thr_list"))
    }
    guard case .threadUnarchiveRequest(let unarchive) = try await nextRequest(peer) else {
      Issue.record("Expected thread/unarchive generated request.")
      return
    }
    #expect(unarchive.method == .threadUnarchive)
    peer.receiveLine(
      try responseLine(
        id: unarchive.id,
        result: Stable.ThreadUnarchiveResponse(thread: thread(id: "thr_unarchived"))
      ))
    #expect(try await unarchiveTask.value.thread.id == "thr_unarchived")

    let unsubscribeTask = Task {
      try await connection.threadUnsubscribe(.init(threadId: "thr_list"))
    }
    guard case .threadUnsubscribeRequest(let unsubscribe) = try await nextRequest(peer) else {
      Issue.record("Expected thread/unsubscribe generated request.")
      return
    }
    #expect(unsubscribe.method == .threadUnsubscribe)
    peer.receiveLine(
      try responseLine(
        id: unsubscribe.id,
        result: Stable.ThreadUnsubscribeResponse(status: .unsubscribed)
      ))
    #expect(try await unsubscribeTask.value.status == .unsubscribed)

    let nameTask = Task {
      try await connection.threadNameSet(.init(name: "Renamed", threadId: "thr_list"))
    }
    guard case .threadNameSetRequest(let name) = try await nextRequest(peer) else {
      Issue.record("Expected thread/name/set generated request.")
      return
    }
    #expect(name.method == .threadNameSet)
    #expect(name.params.name == "Renamed")
    peer.receiveLine(try responseLine(id: name.id, result: Stable.ThreadSetNameResponse()))
    #expect(try await nameTask.value.isEmpty)

    let metadataTask = Task {
      try await connection.threadMetadataUpdate(.init(threadId: "thr_list"))
    }
    guard case .threadMetadataUpdateRequest(let metadata) = try await nextRequest(peer) else {
      Issue.record("Expected thread/metadata/update generated request.")
      return
    }
    #expect(metadata.method == .threadMetadataUpdate)
    peer.receiveLine(
      try responseLine(
        id: metadata.id,
        result: Stable.ThreadMetadataUpdateResponse(thread: thread(id: "thr_metadata"))
      ))
    #expect(try await metadataTask.value.thread.id == "thr_metadata")

    let compactTask = Task {
      try await connection.threadCompactStart(.init(threadId: "thr_list"))
    }
    guard case .threadCompactStartRequest(let compact) = try await nextRequest(peer) else {
      Issue.record("Expected thread/compact/start generated request.")
      return
    }
    #expect(compact.method == .threadCompactStart)
    peer.receiveLine(try responseLine(id: compact.id, result: Stable.ThreadCompactStartResponse()))
    #expect(try await compactTask.value.isEmpty)

    let shellTask = Task {
      try await connection.threadShellCommand(
        .init(
          command: "npm test",
          threadId: "thr_list"
        ))
    }
    guard case .threadShellCommandRequest(let shell) = try await nextRequest(peer) else {
      Issue.record("Expected thread/shellCommand generated request.")
      return
    }
    #expect(shell.method == .threadShellCommand)
    #expect(shell.params.command == "npm test")
    peer.receiveLine(try responseLine(id: shell.id, result: Stable.ThreadShellCommandResponse()))
    #expect(try await shellTask.value.isEmpty)

    let rollbackTask = Task {
      try await connection.threadRollback(.init(numTurns: 2, threadId: "thr_list"))
    }
    guard case .threadRollbackRequest(let rollback) = try await nextRequest(peer) else {
      Issue.record("Expected thread/rollback generated request.")
      return
    }
    #expect(rollback.method == .threadRollback)
    #expect(rollback.params.numTurns == 2)
    peer.receiveLine(
      try responseLine(
        id: rollback.id,
        result: Stable.ThreadRollbackResponse(thread: thread(id: "thr_rollback"))
      ))
    #expect(try await rollbackTask.value.thread.id == "thr_rollback")

    let injectTask = Task {
      try await connection.threadInjectItems(
        .init(
          items: [.object(["type": .string("note")])],
          threadId: "thr_list"
        ))
    }
    guard case .threadInjectItemsRequest(let inject) = try await nextRequest(peer) else {
      Issue.record("Expected thread/inject_items generated request.")
      return
    }
    #expect(inject.method == .threadInjectItems)
    #expect(inject.params.items == [.object(["type": .string("note")])])
    peer.receiveLine(try responseLine(id: inject.id, result: Stable.ThreadInjectItemsResponse()))
    #expect(try await injectTask.value.isEmpty)

    await connection.close()
  }

  @Test("Turn and review follow-on binding sends stable turn and review requests")
  func turnAndReviewFollowOnBindingSendsStableTurnAndReviewRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startThreadTurnReviewReadyConnection(peer: peer)

    let steerTask = Task {
      try await connection.turnSteer(
        .init(
          expectedTurnId: "turn_current",
          input: [.text(.init(text: "Add coverage", type: .text))],
          threadId: "thr_turn"
        ))
    }
    guard case .turnSteerRequest(let steer) = try await nextRequest(peer) else {
      Issue.record("Expected turn/steer generated request.")
      return
    }
    #expect(steer.method == .turnSteer)
    #expect(steer.params.expectedTurnId == "turn_current")
    peer.receiveLine(
      try responseLine(
        id: steer.id,
        result: Stable.TurnSteerResponse(turnId: "turn_steered")
      ))
    #expect(try await steerTask.value.turnId == "turn_steered")

    let interruptTask = Task {
      try await connection.turnInterrupt(.init(threadId: "thr_turn", turnId: "turn_current"))
    }
    guard case .turnInterruptRequest(let interrupt) = try await nextRequest(peer) else {
      Issue.record("Expected turn/interrupt generated request.")
      return
    }
    #expect(interrupt.method == .turnInterrupt)
    #expect(interrupt.params.turnId == "turn_current")
    peer.receiveLine(try responseLine(id: interrupt.id, result: Stable.TurnInterruptResponse()))
    #expect(try await interruptTask.value.isEmpty)

    let reviewTask = Task {
      try await connection.reviewStart(
        .init(
          delivery: .inline,
          target: .custom(.init(instructions: "Review the current diff", type: .custom)),
          threadId: "thr_turn"
        ))
    }
    guard case .reviewStartRequest(let review) = try await nextRequest(peer) else {
      Issue.record("Expected review/start generated request.")
      return
    }
    #expect(review.method == .reviewStart)
    #expect(review.params.delivery == .inline)
    guard case .custom(let target) = review.params.target else {
      Issue.record("Expected custom review target.")
      return
    }
    #expect(target.instructions == "Review the current diff")
    peer.receiveLine(
      try responseLine(
        id: review.id,
        result: Stable.ReviewStartResponse(
          reviewThreadId: "thr_review",
          turn: turn(id: "turn_review")
        )
      ))
    let reviewResponse = try await reviewTask.value
    #expect(reviewResponse.reviewThreadId == "thr_review")
    #expect(reviewResponse.turn.id == "turn_review")

    await connection.close()
  }

}
private func startThreadTurnReviewReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeThreadTurnReviewClient(peer: peer).start()
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

private func makeThreadTurnReviewClient(
  peer: CodexAppServerInMemoryLinePeer
) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_thread_turn_review_tests",
        title: "swift-codex Thread Turn Review Tests",
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
      userAgent: "Codex/swift-codex-thread-turn-review-fixture"
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

private func threadForkResponse(threadID: String) -> Stable.ThreadForkResponse {
  Stable.ThreadForkResponse(
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
