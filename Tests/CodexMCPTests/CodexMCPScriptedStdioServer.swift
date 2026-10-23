import Darwin
import Foundation
import _CodexProcess

@testable import CodexMCP

final class CodexMCPScriptedStdioServer: @unchecked Sendable {
  let client: CodexMCPClient

  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe
  private let transcript = CodexMCPStdioTranscript()

  init() {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      }
    )
  }

  func start() async throws {
    let serverTask = Task {
      let initializeLine = try await readClientLine()
      await transcript.record(initializeLine)
      let initializePayload = try Self.parseJSONObject(from: initializeLine)
      try await sendServerLine(
        Self.makeInitializeResponseLine(requestID: initializePayload["id"] ?? 0))

      let initializedLine = try await readClientLine()
      await transcript.record(initializedLine)
    }

    try await client.start()
    try await serverTask.value
  }

  func readClientLine() async throws -> String {
    try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
  }

  func tryReadAvailableClientLine() async throws -> String? {
    try await tryReadAvailableLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
  }

  func recordClientLine() async throws -> String {
    let line = try await readClientLine()
    await transcript.record(line)
    return line
  }

  func sendServerLine(_ line: String) async throws {
    try await CodexProcessPipe.write(Data(line.utf8), to: stdoutPipe.fileHandleForWriting)
    if !line.hasSuffix("\n") {
      try await CodexProcessPipe.write(Data("\n".utf8), to: stdoutPipe.fileHandleForWriting)
    }
  }

  func closeServerOutput() {
    stdoutPipe.fileHandleForWriting.closeFile()
  }

  func transcriptLines() async -> [String] {
    await transcript.lines
  }

  func nextApprovalRequest(from handle: CodexMCPCallHandle) async throws -> CodexMCPApprovalRequest
  {
    for await request in handle.approvalRequests {
      return request
    }

    throw CodexMCPError.approvalFlowFailure
  }

  func collectServerMessages(from handle: CodexMCPCallHandle) async -> [CodexMCPServerMessage] {
    var messages: [CodexMCPServerMessage] = []
    for await message in handle.serverMessages {
      messages.append(message)
    }
    return messages
  }

  static func parseJSONObject(from line: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    guard let dictionary = object as? [String: Any] else {
      throw CodexMCPError.protocolFailure
    }
    return dictionary
  }

  static func requiredObject(_ key: String, in object: [String: Any]) throws -> [String: Any] {
    guard let nestedObject = object[key] as? [String: Any] else {
      throw CodexMCPError.protocolFailure
    }
    return nestedObject
  }

  static func makeInitializeResponseLine(requestID: Any) -> String {
    """
    {"jsonrpc":"2.0","id":\(jsonLiteral(requestID)),"result":{"capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"codex-mcp-server","title":"Codex","version":"0.0.0","user_agent":"codex/0.0.0"},"protocolVersion":"2025-03-26"}}
    """
  }

  static func makeListToolsResponseLine(requestID: Int) -> String {
    """
    {"jsonrpc":"2.0","id":\(requestID),"result":{"tools":[{"name":"codex","title":"Codex","description":"Run a Codex session.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}},{"name":"codex-reply","title":"Codex Reply","description":"Continue a Codex conversation by providing the thread id and prompt.","inputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"prompt":{"type":"string"}},"required":["threadId","prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}}]}}
    """
  }

  static func makeRunSuccessResponseLine(
    requestID: Int,
    threadID: String,
    content: String
  ) -> String {
    """
    {"jsonrpc":"2.0","id":\(requestID),"result":{"content":[{"type":"text","text":"\(content)"}],"structuredContent":{"threadId":"\(threadID)","content":"\(content)"}}}
    """
  }

  static func makeReplySuccessResponseLine(
    requestID: Int,
    threadID: String,
    content: String
  ) -> String {
    makeRunSuccessResponseLine(
      requestID: requestID,
      threadID: threadID,
      content: content
    )
  }

  static func makeExecApprovalRequestLine(
    requestID: CodexMCPRequestID,
    toolCallID: String,
    threadID: String,
    eventID: String,
    command: [String],
    cwd: String
  ) -> String {
    let encodedRequestID: String
    switch requestID {
    case .integer(let integer):
      encodedRequestID = "\(integer)"
    case .string(let string):
      encodedRequestID = "\"\(string)\""
    }

    let commandValues = command.map { "\"\($0)\"" }.joined(separator: ",")

    return """
      {"jsonrpc":"2.0","id":\(encodedRequestID),"method":"elicitation/create","params":{"message":"Allow Codex?","requestedSchema":{"type":"object","properties":{}},"threadId":"\(threadID)","codex_elicitation":"exec-approval","codex_mcp_tool_call_id":"\(toolCallID)","codex_event_id":"\(eventID)","codex_call_id":"call1234","codex_command":[\(commandValues)],"codex_cwd":"\(cwd)","codex_parsed_cmd":[{"type":"command","cmd":"touch"}]}}
      """
  }

  static func expectedToolDescriptors() -> [CodexMCPToolDescriptor] {
    [
      CodexMCPToolDescriptor(
        name: "codex",
        title: "Codex",
        description: "Run a Codex session.",
        inputSchema: [
          "type": .string("object"),
          "properties": .object([
            "prompt": .object([
              "type": .string("string")
            ])
          ]),
          "required": .array([
            .string("prompt")
          ]),
        ],
        outputSchema: [
          "type": .string("object"),
          "properties": .object([
            "threadId": .object([
              "type": .string("string")
            ]),
            "content": .object([
              "type": .string("string")
            ]),
          ]),
          "required": .array([
            .string("threadId"),
            .string("content"),
          ]),
        ]
      ),
      CodexMCPToolDescriptor(
        name: "codex-reply",
        title: "Codex Reply",
        description: "Continue a Codex conversation by providing the thread id and prompt.",
        inputSchema: [
          "type": .string("object"),
          "properties": .object([
            "threadId": .object([
              "type": .string("string")
            ]),
            "prompt": .object([
              "type": .string("string")
            ]),
          ]),
          "required": .array([
            .string("threadId"),
            .string("prompt"),
          ]),
        ],
        outputSchema: [
          "type": .string("object"),
          "properties": .object([
            "threadId": .object([
              "type": .string("string")
            ]),
            "content": .object([
              "type": .string("string")
            ]),
          ]),
          "required": .array([
            .string("threadId"),
            .string("content"),
          ]),
        ]
      ),
    ]
  }

  private static func jsonLiteral(_ value: Any) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: value,
      options: [.fragmentsAllowed],
    )
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "0"
  }

}

private actor CodexMCPStdioTranscript {
  private(set) var lines: [String] = []

  func record(_ line: String) {
    lines.append(line)
  }
}
