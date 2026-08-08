import Darwin
import Foundation

@testable import CodexMCP

let testMCPClientInfo = CodexMCPClientInfo(
  name: "swift-codex-tests",
  title: "swift-codex Tests",
  version: "0.1.0",
  requestedProtocolVersion: "2025-03-26"
)

actor AsyncPause {
  private var hasEntered = false
  private var enterContinuation: CheckedContinuation<Void, Never>?
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func enter() async {
    hasEntered = true
    enterContinuation?.resume()
    enterContinuation = nil

    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else {
      return
    }

    await withCheckedContinuation { continuation in
      enterContinuation = continuation
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

actor LaunchRecorder {
  private(set) var configurations: [CodexMCPSubprocessLaunchConfiguration] = []

  func record(_ configuration: CodexMCPSubprocessLaunchConfiguration) {
    configurations.append(configuration)
  }
}

actor TerminationRecorder {
  private(set) var terminationCount = 0

  func recordTermination() {
    terminationCount += 1
  }
}

actor TaskProbe {
  private var hasStarted = false
  private var hasCompleted = false
  private var startContinuation: CheckedContinuation<Void, Never>?

  var didComplete: Bool {
    hasCompleted
  }

  func markStarted() {
    hasStarted = true
    startContinuation?.resume()
    startContinuation = nil
  }

  func markCompleted() {
    hasCompleted = true
  }

  func waitUntilStarted() async {
    guard !hasStarted else {
      return
    }

    await withCheckedContinuation { continuation in
      startContinuation = continuation
    }
  }
}

actor HandshakeTranscript {
  private(set) var lines: [String] = []

  func record(_ line: String) {
    lines.append(line)
  }
}

enum FakeLifecycleError: Error {
  case failure
}

func makeStartupMetadata() -> CodexMCPStartupMetadata {
  .init(
    protocolVersion: "2025-03-26",
    serverInfo: .init(
      name: "codex-mcp-server",
      title: "Codex",
      version: "0.0.0",
      userAgent: "codex/0.0.0",
    ),
  )
}

func makeTestSubprocess(
  terminateHandler: @escaping @Sendable () async throws -> Void = {},
) -> CodexMCPManagedSubprocess {
  let stdinPipe = Pipe()
  let stdoutPipe = Pipe()
  let stdinFileDescriptor = stdinPipe.fileHandleForReading.fileDescriptor
  let stdoutFileDescriptor = stdoutPipe.fileHandleForWriting.fileDescriptor
  let handshakeTask = Task {
    try await performStartupHandshake(
      inputFileDescriptor: stdinFileDescriptor,
      outputFileDescriptor: stdoutFileDescriptor,
    )
  }

  return CodexMCPManagedSubprocess(
    standardInput: stdinPipe,
    standardOutput: stdoutPipe,
    standardError: Pipe(),
  ) {
    handshakeTask.cancel()
    try await terminateHandler()
  }
}

func startClient(
  _ client: CodexMCPClient,
  stdinPipe: Pipe,
  stdoutPipe: Pipe
) async throws {
  let handshakeTask = Task {
    try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
  }
  try await client.start()
  try await handshakeTask.value
}

func performStartupHandshake(
  stdinPipe: Pipe,
  stdoutPipe: Pipe,
  transcript: HandshakeTranscript? = nil
) async throws {
  try await performStartupHandshake(
    inputFileDescriptor: stdinPipe.fileHandleForReading.fileDescriptor,
    outputFileDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor,
    transcript: transcript,
  )
}

func performStartupHandshake(
  inputFileDescriptor: Int32,
  outputFileDescriptor: Int32,
  transcript: HandshakeTranscript? = nil
) async throws {
  let initializeLine = try await readLine(from: inputFileDescriptor)
  await transcript?.record(initializeLine)
  let initializePayload = try parseJSONObject(from: initializeLine)
  try blockingWriteLine(
    makeInitializeResponseLine(requestID: initializePayload["id"] ?? 0),
    to: outputFileDescriptor,
  )

  let initializedLine = try await readLine(from: inputFileDescriptor)
  await transcript?.record(initializedLine)
}

func makeInitializeResponseLine(requestID: Any) -> String {
  """
  {"jsonrpc":"2.0","id":\(jsonLiteral(requestID)),"result":{"capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"codex-mcp-server","title":"Codex","version":"0.0.0","user_agent":"codex/0.0.0"},"protocolVersion":"2025-03-26"}}
  """
}

func jsonLiteral(_ value: Any) -> String {
  let data = try? JSONSerialization.data(
    withJSONObject: value,
    options: [.fragmentsAllowed],
  )
  return data.flatMap { String(data: $0, encoding: .utf8) } ?? "0"
}

func isAbsentOrEmptyObject(_ value: Any?) -> Bool {
  value == nil || (value as? [String: Any])?.isEmpty == true
}

func makePingSuccessResponseLine(requestID: Int) -> String {
  """
  {"jsonrpc":"2.0","id":\(requestID),"result":{}}
  """
}

func makeListToolsResponseLine(requestID: Int) -> String {
  """
  {"jsonrpc":"2.0","id":\(requestID),"result":{"tools":[{"name":"codex","title":"Codex","description":"Run a Codex session.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}},{"name":"codex-reply","title":"Codex Reply","description":"Continue a Codex conversation by providing the thread id and prompt.","inputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"prompt":{"type":"string"}},"required":["threadId","prompt"]},"outputSchema":{"type":"object","properties":{"threadId":{"type":"string"},"content":{"type":"string"}},"required":["threadId","content"]}}]}}
  """
}

func makeRunCodexSuccessResponseLine(
  requestID: Int,
  threadID: String,
  content: String,
) -> String {
  """
  {"jsonrpc":"2.0","id":\(requestID),"result":{"content":[{"type":"text","text":"\(content)"}],"structuredContent":{"threadId":"\(threadID)","content":"\(content)"}}}
  """
}

func makeReplySuccessResponseLine(
  requestID: Int,
  threadID: String,
  content: String,
) -> String {
  """
  {"jsonrpc":"2.0","id":\(requestID),"result":{"content":[{"type":"text","text":"\(content)"}],"structuredContent":{"threadId":"\(threadID)","content":"\(content)"}}}
  """
}

func makeExecApprovalRequestLine(
  requestID: CodexMCPRequestID,
  toolCallID: String,
  threadID: String,
  eventID: String,
  command: [String],
  cwd: String,
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

func makePatchApprovalRequestLine(
  requestID: CodexMCPRequestID,
  toolCallID: String,
  threadID: String,
  eventID: String,
  reason: String?,
  grantRoot: String?,
  changes: [String: CodexMCPJSONValue],
) -> String {
  let requestIDValue: Any
  switch requestID {
  case .integer(let integer):
    requestIDValue = integer
  case .string(let string):
    requestIDValue = string
  }

  let payload: [String: Any] = [
    "jsonrpc": "2.0",
    "id": requestIDValue,
    "method": "elicitation/create",
    "params": [
      "message": "Allow Codex to apply proposed code changes?",
      "requestedSchema": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
      "threadId": threadID,
      "codex_elicitation": "patch-approval",
      "codex_mcp_tool_call_id": toolCallID,
      "codex_event_id": eventID,
      "codex_call_id": "call5678",
      "codex_reason": reason as Any,
      "codex_grant_root": grantRoot as Any,
      "codex_changes": jsonObject(from: changes),
    ],
  ]

  let data = try! JSONSerialization.data(withJSONObject: payload)
  return String(decoding: data, as: UTF8.self)
}

func makeExpectedToolDescriptors() -> [CodexMCPToolDescriptor] {
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
      ],
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
      ],
    ),
  ]
}

func makeExpectedRunCodexResult(
  threadID: String,
  content: String,
) -> CodexMCPToolResult {
  CodexMCPToolResult(
    threadID: threadID,
    content: content,
    rawContentBlocks: [
      .object([
        "type": .string("text"),
        "text": .string(content),
      ])
    ],
    rawStructuredContent: .object([
      "threadId": .string(threadID),
      "content": .string(content),
    ]),
    isError: false,
  )
}

func requestID(
  forMethod method: String,
  from payloads: [[String: Any]]
) throws -> Int {
  guard let payload = payloads.first(where: { $0["method"] as? String == method }) else {
    throw FakeLifecycleError.failure
  }

  return try requiredInteger("id", in: payload)
}

func requiredInteger(
  _ key: String,
  in object: [String: Any]
) throws -> Int {
  guard let number = object[key] as? NSNumber else {
    throw FakeLifecycleError.failure
  }

  return number.intValue
}

func jsonObject(from value: [String: CodexMCPJSONValue]) -> Any {
  value.reduce(into: [String: Any]()) { partialResult, entry in
    partialResult[entry.key] = foundationObject(from: entry.value)
  }
}

func foundationObject(from value: CodexMCPJSONValue) -> Any {
  switch value {
  case .object(let object):
    return jsonObject(from: object)
  case .array(let array):
    return array.map(foundationObject(from:))
  case .string(let string):
    return string
  case .integer(let integer):
    return integer
  case .double(let number):
    return number
  case .bool(let bool):
    return bool
  case .null:
    return NSNull()
  }
}

func parseJSONObject(from line: String) throws -> [String: Any] {
  let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
  guard let dictionary = object as? [String: Any] else {
    throw CodexMCPError.protocolFailure
  }

  return dictionary
}

func cancelledNotificationPayload(in lines: [String]) throws -> [String: Any] {
  for line in lines {
    let payload = try parseJSONObject(from: line)
    if payload["method"] as? String == "notifications/cancelled" {
      return payload
    }
  }

  throw CodexMCPError.protocolFailure
}

func requiredObject(_ key: String, in object: [String: Any]) throws -> [String: Any] {
  guard let nestedObject = object[key] as? [String: Any] else {
    throw CodexMCPError.protocolFailure
  }

  return nestedObject
}

let blockingIOTestQueue = DispatchQueue(
  label: "swift-codex.tests.codexmcp.blocking-io",
  qos: .userInitiated,
  attributes: .concurrent
)

func readLine(from fileDescriptor: Int32) async throws -> String {
  try await withCheckedThrowingContinuation { continuation in
    blockingIOTestQueue.async {
      do {
        continuation.resume(returning: try blockingReadLine(from: fileDescriptor))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

func blockingReadLine(from fileDescriptor: Int32) throws -> String {
  var buffer = Data()
  var byte: UInt8 = 0

  while true {
    let bytesRead = withUnsafeMutablePointer(to: &byte) { bytePointer in
      Darwin.read(fileDescriptor, bytePointer, 1)
    }

    if bytesRead > 0 {
      if byte == 0x0A {
        break
      }

      buffer.append(&byte, count: 1)
      continue
    }

    if bytesRead == 0 {
      throw CodexMCPError.startupFailure
    }

    if errno == EINTR {
      continue
    }

    throw CodexMCPError.transportFailure
  }

  if buffer.last == 0x0D {
    buffer.removeLast()
  }

  guard let line = String(data: buffer, encoding: .utf8) else {
    throw CodexMCPError.transportFailure
  }

  return line
}

func blockingWriteLine(_ line: String, to fileDescriptor: Int32) throws {
  var data = Data(line.utf8)
  data.append(0x0A)
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    var bytesWrittenTotal = 0
    while bytesWrittenTotal < rawBuffer.count {
      let bytesWritten = Darwin.write(
        fileDescriptor,
        baseAddress.advanced(by: bytesWrittenTotal),
        rawBuffer.count - bytesWrittenTotal,
      )

      if bytesWritten > 0 {
        bytesWrittenTotal += bytesWritten
        continue
      }

      if bytesWritten < 0 && errno == EINTR {
        continue
      }

      throw CodexMCPError.transportFailure
    }
  }
}

func readExactly(byteCount: Int, from fileDescriptor: Int32) throws -> Data {
  var buffer = [UInt8](repeating: 0, count: byteCount)
  var bytesReadTotal = 0

  while bytesReadTotal < byteCount {
    let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(
        fileDescriptor,
        rawBuffer.baseAddress?.advanced(by: bytesReadTotal),
        byteCount - bytesReadTotal,
      )
    }

    if bytesRead > 0 {
      bytesReadTotal += bytesRead
      continue
    }

    if errno == EINTR {
      continue
    }

    throw CodexMCPError.transportFailure
  }

  return Data(buffer)
}

func tryReadAvailableLine(from fileDescriptor: Int32) throws -> String? {
  var descriptor = pollfd(
    fd: fileDescriptor,
    events: Int16(POLLIN),
    revents: 0,
  )

  let result = Darwin.poll(&descriptor, 1, 0)
  if result < 0 {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  guard result > 0 else {
    return nil
  }

  return try blockingReadLine(from: fileDescriptor)
}

func nextApprovalRequest(from handle: CodexMCPCallHandle) async throws -> CodexMCPApprovalRequest {
  for await approvalRequest in handle.approvalRequests {
    return approvalRequest
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
