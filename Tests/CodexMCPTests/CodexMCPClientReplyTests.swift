import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Client Reply", .serialized)
struct CodexMCPClientReplyTests {
  @Test(
    "Lifecycle shell reply sends the codex-reply tool request and returns a terminal tool result")
  func replySendsCodexReplyToolRequestAndReturnsTerminalToolResult() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()
    let request = CodexMCPReplyRequest(
      threadID: "thread-123",
      prompt: "continue the thread",
    )

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let replyLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(replyLine)

      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"method\":\"codex/event\",\"params\":{\"_meta\":{\"requestId\":1,\"threadId\":\"thread-123\"},\"id\":\"event-reply-1\",\"msg\":{\"type\":\"reply-progress\"}}}\n"
            .utf8)
      )
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeReplySuccessResponseLine(requestID: 1, threadID: "thread-123", content: "Continued")
            .utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let handle = try await client.reply(request)
    let serverMessagesTask = Task {
      await collectServerMessages(from: handle)
    }
    let result = try await handle.value()
    try await serverTask.value

    let requestID = handle.requestID
    let serverMessages = await serverMessagesTask.value
    let replyPayload = try parseJSONObject(from: await transcript.lines[0])
    let params = try requiredObject("params", in: replyPayload)
    let arguments = try requiredObject("arguments", in: params)
    let state = await client.state

    #expect(requestID == .integer(1))
    #expect(replyPayload["jsonrpc"] as? String == "2.0")
    #expect(replyPayload["method"] as? String == "tools/call")
    #expect((replyPayload["id"] as? NSNumber)?.intValue == 1)
    #expect(params["name"] as? String == "codex-reply")
    #expect(arguments["threadId"] as? String == "thread-123")
    #expect(arguments["prompt"] as? String == "continue the thread")
    #expect(arguments["conversationId"] == nil)
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-123", content: "Continued"))
    #expect(
      serverMessages == [
        CodexMCPServerMessage(
          method: "codex/event",
          rawEvent: .object([
            "id": .string("event-reply-1"),
            "msg": .object([
              "type": .string("reply-progress")
            ]),
          ]),
          requestID: .integer(1),
          threadID: "thread-123",
        )
      ])
    #expect(state == .running)
  }

  @Test("Lifecycle shell preserves codex-reply tool-level errors as terminal tool results")
  func replyPreservesToolLevelErrorResults() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Reply failed\"}],\"isError\":true}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let handle = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))
    let result = try await handle.value()
    try await serverTask.value

    #expect(result.threadID == nil)
    #expect(result.content == "Reply failed")
    #expect(result.isError == true)
    #expect(result.rawStructuredContent == nil)
  }

  @Test("Lifecycle shell maps reply JSON-RPC error response to the CodexMCP error surface")
  func replyJSONRPCErrorUsesCodexMCPErrorSurface() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"internal error\"}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let handle = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))

    await #expect(
      throws: CodexMCPError.jsonrpcFailure(
        .init(code: -32603, message: "internal error"))
    ) {
      try await handle.value()
    }

    try await serverTask.value

    let state = await client.state
    #expect(state == .running)
  }

  @Test(
    "Lifecycle shell treats cancellation of an unknown request id as a non-fatal no-op while running"
  )
  func unknownRequestCancellationIsNonFatalNoOp() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await startClient(client, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
    let didCancel = try await client.cancel(requestID: .integer(999))
    let extraLine = try tryReadAvailableLine(from: stdinPipe.fileHandleForReading.fileDescriptor)

    #expect(didCancel == false)
    #expect(extraLine == nil)
  }

  @Test("Lifecycle shell round-trips patch approval requests through the reply handle")
  func replyPatchApprovalRoundTripsThroughHandle() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let replyLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(replyLine)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makePatchApprovalRequestLine(
            requestID: .string("patch-approval-1"),
            toolCallID: "1",
            threadID: "thread-123",
            eventID: "event-patch-1",
            reason: "Patch needs approval",
            grantRoot: "/tmp/codex-grant-root",
            changes: [
              "/tmp/file.swift": .object([
                "status": .string("modified")
              ])
            ]
          ).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))

      let approvalResponseLine = try await readLine(
        from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(approvalResponseLine)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Patch denied\"}],\"isError\":true}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let handle = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))
    let approvalRequest = try await nextApprovalRequest(from: handle)

    guard case .patch(let patchApproval) = approvalRequest else {
      Issue.record("Expected patch approval request.")
      return
    }

    #expect(patchApproval.requestID == .string("patch-approval-1"))
    #expect(patchApproval.originatingRequestID == .integer(1))
    #expect(patchApproval.threadID == "thread-123")
    #expect(patchApproval.codexEventID == "event-patch-1")
    #expect(patchApproval.reason == "Patch needs approval")
    #expect(patchApproval.grantRoot == "/tmp/codex-grant-root")
    #expect(
      patchApproval.changes == [
        "/tmp/file.swift": .object([
          "status": .string("modified")
        ])
      ])

    try await handle.respond(to: approvalRequest.requestID, with: .deny)
    let result = try await handle.value()
    try await serverTask.value

    let lines = await transcript.lines
    let replyPayload = try parseJSONObject(from: lines[0])
    let approvalResponsePayload = try parseJSONObject(from: lines[1])
    let state = await client.state

    #expect((replyPayload["id"] as? NSNumber)?.intValue == 1)
    #expect(approvalResponsePayload["id"] as? String == "patch-approval-1")
    #expect(
      try requiredObject("result", in: approvalResponsePayload)["decision"] as? String == "denied")
    #expect(result.threadID == nil)
    #expect(result.content == "Patch denied")
    #expect(result.isError == true)
    #expect(state == .running)
  }

  @Test("Lifecycle shell rejects reply before startup")
  func replyFailsOutsideRunningState() async throws {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .reply, from: .idle)) {
      _ = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))
    }
  }

  @Test("Lifecycle shell rejects successful reply results that switch threads")
  func replyRejectsSuccessfulResultWithDifferentThreadID() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeReplySuccessResponseLine(
            requestID: 1, threadID: "thread-other", content: "Wrong thread"
          ).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let handle = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))

    await #expect(throws: CodexMCPError.protocolFailure) {
      try await handle.value()
    }

    try await serverTask.value
  }

  @Test("Lifecycle shell allows ping while a reply turn is still in flight")
  func replyAllowsLaterPingWhileTurnIsInFlight() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await startClient(client, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
    let handle = try await client.reply(.init(threadID: "thread-123", prompt: "continue"))

    let firstLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(firstLine)

    let pingTask = Task {
      try await client.ping()
    }

    let secondLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(secondLine)
    let firstPayload = try parseJSONObject(from: firstLine)
    let secondPayload = try parseJSONObject(from: secondLine)
    let replyParams = try requiredObject("params", in: firstPayload)
    let replyRequestID = try requiredInteger("id", in: firstPayload)
    let pingRequestID = try requiredInteger("id", in: secondPayload)

    stdoutPipe.fileHandleForWriting.write(
      Data(makePingSuccessResponseLine(requestID: pingRequestID).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    try await pingTask.value
    stdoutPipe.fileHandleForWriting.write(
      Data(
        makeReplySuccessResponseLine(
          requestID: replyRequestID, threadID: "thread-123", content: "Continued"
        ).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    let result = try await handle.value()

    #expect(firstPayload["method"] as? String == "tools/call")
    #expect(replyRequestID == 1)
    #expect(replyParams["name"] as? String == "codex-reply")
    #expect(secondPayload["method"] as? String == "ping")
    #expect(pingRequestID == 2)
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-123", content: "Continued"))
  }

}
