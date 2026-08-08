import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Client Run Codex", .serialized)
struct CodexMCPClientRunCodexTests {
  @Test("Lifecycle shell runCodex sends the codex tool request and returns a terminal tool result")
  func runCodexSendsCodexToolRequestAndReturnsTerminalToolResult() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()
    let request = CodexMCPRunRequest(
      prompt: "implement the feature",
      model: "gpt-5.2-codex",
      profile: "fast",
      cwd: URL(fileURLWithPath: "/tmp/codex-mcp-run"),
      approvalPolicy: .onRequest,
      sandboxMode: .workspaceWrite,
      configOverrides: [
        "reasoning_effort": .string("high"),
        "stream": .bool(true),
      ],
      baseInstructions: "base",
      developerInstructions: "dev",
      compactPrompt: "compact",
    )

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let runLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(runLine)

      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"method\":\"codex/event\",\"params\":{\"_meta\":{\"requestId\":1,\"threadId\":\"thread-123\"},\"id\":\"event-1\",\"msg\":{\"type\":\"noop\"}}}\n"
            .utf8)
      )
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(requestID: 1, threadID: "thread-123", content: "Done")
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
    let handle = try await client.runCodex(request)
    let serverMessagesTask = Task {
      await collectServerMessages(from: handle)
    }
    let result = try await handle.value()
    try await serverTask.value

    let requestID = handle.requestID
    let serverMessages = await serverMessagesTask.value
    let runPayload = try parseJSONObject(from: await transcript.lines[0])
    let params = try requiredObject("params", in: runPayload)
    let arguments = try requiredObject("arguments", in: params)
    let config = try requiredObject("config", in: arguments)
    let state = await client.state

    #expect(requestID == .integer(1))
    #expect(runPayload["jsonrpc"] as? String == "2.0")
    #expect(runPayload["method"] as? String == "tools/call")
    #expect((runPayload["id"] as? NSNumber)?.intValue == 1)
    #expect(params["name"] as? String == "codex")
    #expect(arguments["prompt"] as? String == "implement the feature")
    #expect(arguments["model"] as? String == "gpt-5.2-codex")
    #expect(arguments["profile"] as? String == "fast")
    #expect(arguments["cwd"] as? String == "/tmp/codex-mcp-run")
    #expect(arguments["approval-policy"] as? String == "on-request")
    #expect(arguments["sandbox"] as? String == "workspace-write")
    #expect(arguments["base-instructions"] as? String == "base")
    #expect(arguments["developer-instructions"] as? String == "dev")
    #expect(arguments["compact-prompt"] as? String == "compact")
    #expect(config["reasoning_effort"] as? String == "high")
    #expect(config["stream"] as? Bool == true)
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-123", content: "Done"))
    #expect(
      serverMessages == [
        CodexMCPServerMessage(
          method: "codex/event",
          rawEvent: .object([
            "id": .string("event-1"),
            "msg": .object([
              "type": .string("noop")
            ]),
          ]),
          requestID: .integer(1),
          threadID: "thread-123",
        )
      ])
    #expect(state == .running)
  }

  @Test("Lifecycle shell preserves codex tool-level errors as terminal tool results")
  func runCodexPreservesToolLevelErrorResults() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Failed to start Codex session: boom\"}],\"isError\":true}}\n"
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    let result = try await handle.value()
    try await serverTask.value

    #expect(result.threadID == nil)
    #expect(result.content == "Failed to start Codex session: boom")
    #expect(result.isError == true)
    #expect(result.rawStructuredContent == nil)
  }

  @Test("Lifecycle shell ignores non-goal server requests while a codex tool call is in flight")
  func runCodexIgnoresNonGoalServerRequests() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data("{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"resources/list\",\"params\":{}}\n".utf8)
      )
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(requestID: 1, threadID: "thread-ignore", content: "Done")
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    let result = try await handle.value()
    try await serverTask.value

    #expect(result == makeExpectedRunCodexResult(threadID: "thread-ignore", content: "Done"))
    #expect(await client.state == .running)
  }

  @Test("Lifecycle shell maps runCodex JSON-RPC error response to the CodexMCP error surface")
  func runCodexJSONRPCErrorUsesCodexMCPErrorSurface() async throws {
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
    let handle = try await client.runCodex(.init(prompt: "hi"))

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

  @Test("Lifecycle shell round-trips exec approval requests through the runCodex handle")
  func runCodexExecApprovalRoundTripsThroughHandle() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()
    let request = CodexMCPRunRequest(
      prompt: "hi",
      approvalPolicy: .onRequest,
    )

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let runLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(runLine)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeExecApprovalRequestLine(
            requestID: .integer(88),
            toolCallID: "1",
            threadID: "thread-123",
            eventID: "event-approval-1",
            command: ["touch", "created.txt"],
            cwd: "/tmp/codex-approval"
          ).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))

      let approvalResponseLine = try await readLine(
        from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(approvalResponseLine)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(requestID: 1, threadID: "thread-123", content: "Approved")
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
    let handle = try await client.runCodex(request)
    let approvalRequest = try await nextApprovalRequest(from: handle)

    guard case .exec(let execApproval) = approvalRequest else {
      Issue.record("Expected exec approval request.")
      return
    }

    #expect(execApproval.requestID == .integer(88))
    #expect(execApproval.originatingRequestID == .integer(1))
    #expect(execApproval.threadID == "thread-123")
    #expect(execApproval.codexEventID == "event-approval-1")
    #expect(execApproval.command == ["touch", "created.txt"])
    #expect(execApproval.cwd == "/tmp/codex-approval")
    #expect(
      execApproval.parsedCommand == [
        .object([
          "type": .string("command"),
          "cmd": .string("touch"),
        ])
      ])

    try await handle.respond(to: approvalRequest.requestID, with: .allow)
    let result = try await handle.value()
    try await serverTask.value

    let lines = await transcript.lines
    let runPayload = try parseJSONObject(from: lines[0])
    let approvalResponsePayload = try parseJSONObject(from: lines[1])
    let state = await client.state

    #expect((runPayload["id"] as? NSNumber)?.intValue == 1)
    #expect((approvalResponsePayload["id"] as? NSNumber)?.intValue == 88)
    #expect(
      try requiredObject("result", in: approvalResponsePayload)["decision"] as? String == "approved"
    )
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-123", content: "Approved"))
    #expect(state == .running)
  }

  @Test(
    "Lifecycle shell dispatches request-scoped cancellation and preserves the eventual terminal result"
  )
  func runCodexCancellationDispatchesAndPreservesEventualTerminalOutcome() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let runLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(runLine)

      while true {
        let line = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
        await transcript.record(line)
        let payload = try parseJSONObject(from: line)
        if payload["method"] as? String == "notifications/cancelled" {
          break
        }
      }

      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(
            requestID: 1, threadID: "thread-cancel", content: "Stopped late"
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    let didCancel = try await client.cancel(requestID: handle.requestID)
    let result = try await handle.value()
    try await serverTask.value

    let lines = await transcript.lines
    let cancelPayload = try cancelledNotificationPayload(in: lines)
    let cancelParams = try requiredObject("params", in: cancelPayload)
    let state = await client.state

    #expect(didCancel == true)
    #expect(cancelPayload["jsonrpc"] as? String == "2.0")
    #expect(cancelPayload["method"] as? String == "notifications/cancelled")
    #expect((cancelParams["requestId"] as? NSNumber)?.intValue == 1)
    #expect(
      result == makeExpectedRunCodexResult(threadID: "thread-cancel", content: "Stopped late"))
    #expect(state == .running)
  }

  @Test("Lifecycle shell ignores insufficiently correlated malformed runCodex approval requests")
  func malformedRunCodexApprovalRequestIsIgnored() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"elicitation/create\",\"params\":{\"message\":\"Allow Codex?\",\"codex_elicitation\":\"exec-approval\"}}\n"
            .utf8)
      )
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(
            requestID: 1, threadID: "thread-malformed", content: "Done"
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    let result = try await handle.value()

    try await serverTask.value

    let state = await client.state
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-malformed", content: "Done"))
    #expect(state == .running)
  }

  @Test(
    "Lifecycle shell maps mis-correlated runCodex approval requests to a bounded approval-flow failure"
  )
  func miscorrelatedRunCodexApprovalRequestUsesApprovalFlowFailure() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeExecApprovalRequestLine(
            requestID: .integer(88),
            toolCallID: "999",
            threadID: "thread-123",
            eventID: "event-123",
            command: ["touch", "file.txt"],
            cwd: "/tmp",
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
    let handle = try await client.runCodex(.init(prompt: "hi"))

    await #expect(throws: CodexMCPError.approvalFlowFailure) {
      try await handle.value()
    }

    try await serverTask.value
  }

  @Test(
    "Lifecycle shell ignores uncorrelated approval requests while a codex tool call is in flight")
  func runCodexIgnoresUncorrelatedApprovalRequests() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"elicitation/create\",\"params\":{\"message\":\"Allow Codex?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}},\"threadId\":\"thread-ignore\",\"codex_elicitation\":\"exec-approval\",\"codex_event_id\":\"event-ignore\",\"codex_command\":[\"touch\",\"file.txt\"],\"codex_cwd\":\"/tmp\",\"codex_parsed_cmd\":[{\"type\":\"command\",\"cmd\":\"touch\"}]}}\n"
            .utf8)
      )
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(requestID: 1, threadID: "thread-ignore", content: "Done")
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    let result = try await handle.value()

    try await serverTask.value

    #expect(result == makeExpectedRunCodexResult(threadID: "thread-ignore", content: "Done"))
    #expect(await client.state == .running)
  }

  @Test("Lifecycle shell treats cancellation of an already-finished handle as a non-fatal no-op")
  func completedHandleCancellationIsNonFatalNoOp() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          makeRunCodexSuccessResponseLine(
            requestID: 1, threadID: "thread-finished", content: "Done"
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
    let handle = try await client.runCodex(.init(prompt: "hi"))
    _ = try await handle.value()
    try await serverTask.value

    let didCancel = try await handle.cancel()
    let extraLine = try tryReadAvailableLine(from: stdinPipe.fileHandleForReading.fileDescriptor)

    #expect(didCancel == false)
    #expect(extraLine == nil)
  }

  @Test("Lifecycle shell rejects runCodex before startup")
  func runCodexFailsOutsideRunningState() async throws {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .runCodex, from: .idle)) {
      _ = try await client.runCodex(.init(prompt: "hi"))
    }
  }

  @Test("Lifecycle shell allows ping while a runCodex turn is still in flight")
  func runCodexAllowsLaterPingWhileTurnIsInFlight() async throws {
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
    let handle = try await client.runCodex(.init(prompt: "hi"))

    let firstLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(firstLine)

    let pingTask = Task {
      try await client.ping()
    }

    let secondLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(secondLine)
    let firstPayload = try parseJSONObject(from: firstLine)
    let secondPayload = try parseJSONObject(from: secondLine)
    let toolCallParams = try requiredObject("params", in: firstPayload)
    let runRequestID = try requiredInteger("id", in: firstPayload)
    let pingRequestID = try requiredInteger("id", in: secondPayload)

    stdoutPipe.fileHandleForWriting.write(
      Data(makePingSuccessResponseLine(requestID: pingRequestID).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    try await pingTask.value
    stdoutPipe.fileHandleForWriting.write(
      Data(
        makeRunCodexSuccessResponseLine(
          requestID: runRequestID, threadID: "thread-serialize", content: "Done"
        ).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    let result = try await handle.value()

    #expect(firstPayload["method"] as? String == "tools/call")
    #expect(toolCallParams["name"] as? String == "codex")
    #expect(runRequestID == 1)
    #expect(secondPayload["method"] as? String == "ping")
    #expect(pingRequestID == 2)
    #expect(result == makeExpectedRunCodexResult(threadID: "thread-serialize", content: "Done"))
    try await client.stop()
  }

}
