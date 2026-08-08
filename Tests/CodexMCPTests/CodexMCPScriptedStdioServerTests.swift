import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Scripted Stdio Server", .serialized)
struct CodexMCPScriptedStdioServerTests {
  @Test("Scripted stdio server drives startup handshake through live stdio")
  func scriptedServerDrivesStartupHandshake() async throws {
    let server = CodexMCPScriptedStdioServer()

    try await server.start()

    let lines = await server.transcriptLines()
    let initializePayload = try CodexMCPScriptedStdioServer.parseJSONObject(from: lines[0])
    let initializeParams = try CodexMCPScriptedStdioServer.requiredObject(
      "params", in: initializePayload)
    let initializedPayload = try CodexMCPScriptedStdioServer.parseJSONObject(from: lines[1])
    let startupMetadata = await server.client.startupMetadata

    #expect(initializePayload["method"] as? String == "initialize")
    #expect(initializeParams["protocolVersion"] as? String == "2025-03-26")
    #expect(initializedPayload["method"] as? String == "notifications/initialized")
    #expect(startupMetadata?.protocolVersion == "2025-03-26")
  }

  @Test(
    "Scripted stdio server drives tools/list and preserves the current upstream tool descriptors")
  func scriptedServerDrivesToolsList() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      let requestLine = try await server.recordClientLine()
      let payload = try CodexMCPScriptedStdioServer.parseJSONObject(from: requestLine)
      #expect(payload["method"] as? String == "tools/list")
      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeListToolsResponseLine(requestID: 1)
      )
    }

    let tools = try await server.client.listTools()
    try await serverTask.value

    #expect(tools == CodexMCPScriptedStdioServer.expectedToolDescriptors())
  }

  @Test("Scripted stdio server drives codex tool execution with correlated codex/event delivery")
  func scriptedServerDrivesRunCodexWithCorrelatedEvent() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      _ = try await server.recordClientLine()
      server.sendServerLine(
        #"{"jsonrpc":"2.0","method":"codex/event","params":{"_meta":{"requestId":1,"threadId":"thread-scripted"},"id":"event-1","msg":{"type":"progress"}}}"#
      )
      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeRunSuccessResponseLine(
          requestID: 1,
          threadID: "thread-scripted",
          content: "Done"
        )
      )
    }

    let handle = try await server.client.runCodex(.init(prompt: "hi"))
    let serverMessagesTask = Task {
      await server.collectServerMessages(from: handle)
    }
    let result = try await handle.value()
    let serverMessages = await serverMessagesTask.value
    try await serverTask.value

    #expect(result.threadID == "thread-scripted")
    #expect(result.content == "Done")
    #expect(
      serverMessages == [
        CodexMCPServerMessage(
          method: "codex/event",
          rawEvent: .object([
            "id": .string("event-1"),
            "msg": .object([
              "type": .string("progress")
            ]),
          ]),
          requestID: .integer(1),
          threadID: "thread-scripted"
        )
      ])
  }

  @Test("Scripted stdio server drives codex-reply over scripted stdio")
  func scriptedServerDrivesReplyToolCall() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      let requestLine = try await server.recordClientLine()
      let payload = try CodexMCPScriptedStdioServer.parseJSONObject(from: requestLine)
      let params = try CodexMCPScriptedStdioServer.requiredObject("params", in: payload)
      let arguments = try CodexMCPScriptedStdioServer.requiredObject("arguments", in: params)

      #expect(params["name"] as? String == "codex-reply")
      #expect(arguments["threadId"] as? String == "thread-123")
      #expect(arguments["prompt"] as? String == "continue")

      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeReplySuccessResponseLine(
          requestID: 1,
          threadID: "thread-123",
          content: "Continued"
        )
      )
    }

    let handle = try await server.client.reply(.init(threadID: "thread-123", prompt: "continue"))
    let result = try await handle.value()
    try await serverTask.value

    #expect(result.threadID == "thread-123")
    #expect(result.content == "Continued")
  }

  @Test("Scripted stdio server drives bounded approval round-trips through the runCodex handle")
  func scriptedServerDrivesApprovalRoundTrip() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      _ = try await server.recordClientLine()
      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeExecApprovalRequestLine(
          requestID: .integer(88),
          toolCallID: "1",
          threadID: "thread-approval",
          eventID: "event-approval",
          command: ["touch", "created.txt"],
          cwd: "/tmp/codex-approval"
        )
      )

      let approvalResponseLine = try await server.recordClientLine()
      let approvalResponsePayload = try CodexMCPScriptedStdioServer.parseJSONObject(
        from: approvalResponseLine)
      #expect((approvalResponsePayload["id"] as? NSNumber)?.intValue == 88)
      #expect(
        try CodexMCPScriptedStdioServer.requiredObject("result", in: approvalResponsePayload)[
          "decision"] as? String == "approved")

      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeRunSuccessResponseLine(
          requestID: 1,
          threadID: "thread-approval",
          content: "Approved"
        )
      )
    }

    let handle = try await server.client.runCodex(.init(prompt: "hi", approvalPolicy: .onRequest))
    let approvalRequest = try await server.nextApprovalRequest(from: handle)
    try await handle.respond(to: approvalRequest.requestID, with: .allow)
    let result = try await handle.value()
    try await serverTask.value

    #expect(approvalRequest.originatingRequestID == .integer(1))
    #expect(approvalRequest.threadID == "thread-approval")
    #expect(result.threadID == "thread-approval")
    #expect(result.content == "Approved")
  }

  @Test(
    "Scripted stdio server drives request-scoped cancellation dispatch and preserves the eventual terminal outcome"
  )
  func scriptedServerDrivesCancellation() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      _ = try await server.recordClientLine()
      let cancelPayload: [String: Any]
      while true {
        let line = try await server.recordClientLine()
        let payload = try CodexMCPScriptedStdioServer.parseJSONObject(from: line)
        if payload["method"] as? String == "notifications/cancelled" {
          cancelPayload = payload
          break
        }
      }
      let cancelParams = try CodexMCPScriptedStdioServer.requiredObject("params", in: cancelPayload)

      #expect(cancelPayload["method"] as? String == "notifications/cancelled")
      #expect((cancelParams["requestId"] as? NSNumber)?.intValue == 1)

      server.sendServerLine(
        CodexMCPScriptedStdioServer.makeRunSuccessResponseLine(
          requestID: 1,
          threadID: "thread-cancel",
          content: "Stopped late"
        )
      )
    }

    let handle = try await server.client.runCodex(.init(prompt: "hi"))
    let didCancel = try await handle.cancel()
    let result = try await handle.value()
    try await serverTask.value

    #expect(didCancel == true)
    #expect(result.threadID == "thread-cancel")
    #expect(result.content == "Stopped late")
  }

  @Test("Scripted stdio server surfaces transport failure after startup")
  func scriptedServerSurfacesTransportFailure() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      _ = try await server.recordClientLine()
      server.closeServerOutput()
    }

    await #expect(throws: CodexMCPError.transportFailure) {
      _ = try await server.client.listTools()
    }

    try await serverTask.value
  }

  @Test("Scripted stdio server surfaces protocol failure for malformed tools/list results")
  func scriptedServerSurfacesProtocolFailure() async throws {
    let server = CodexMCPScriptedStdioServer()
    try await server.start()

    let serverTask = Task {
      _ = try await server.recordClientLine()
      server.sendServerLine(#"{"jsonrpc":"2.0","id":1,"result":{"oops":true}}"#)
    }

    await #expect(throws: CodexMCPError.protocolFailure) {
      _ = try await server.client.listTools()
    }

    try await serverTask.value
  }
}
