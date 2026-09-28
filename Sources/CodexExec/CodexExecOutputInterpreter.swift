import Foundation

struct CodexExecDecodedOutput: Equatable, Sendable {
  var finalMessageText: String?
  var events: [CodexExecEvent]
  var resolvedSessionID: String?

  var partialObservation: CodexExecPartialObservation {
    CodexExecPartialObservation(
      finalMessageText: finalMessageText,
      events: events,
      resolvedSessionID: resolvedSessionID
    )
  }
}

/// Decoder for upstream `codex exec --json` JSONL event output.
public struct CodexExecJSONLDecoder: Sendable {
  /// Creates a JSONL decoder.
  public init() {}

  /// Decodes one JSONL line into a canonical exec event.
  public func decodeLine(_ line: String) throws -> CodexExecEvent {
    try Self.decodeEvent(from: line)
  }

  /// Decodes an async line stream into an async event stream.
  public func decode<S: AsyncSequence>(
    _ lines: S
  ) -> AsyncThrowingStream<CodexExecEvent, Error> where S.Element == String, S: Sendable {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await line in lines {
            continuation.yield(try decodeLine(line))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  func decode(lines: [String]) throws -> [CodexExecEvent] {
    try lines.map(decodeLine)
  }

  func inspect(lines: [String]) throws -> CodexExecDecodedOutput {
    var events: [CodexExecEvent] = []
    var finalMessageText: String?
    var resolvedSessionID: String?

    for line in lines {
      let event = try decodeLine(line)
      events.append(event)

      if resolvedSessionID == nil, case .threadStarted(let id) = event {
        resolvedSessionID = id
      }

      if let agentMessageText = Self.extractedFinalMessageText(from: event) {
        finalMessageText = agentMessageText
      }
    }

    return CodexExecDecodedOutput(
      finalMessageText: finalMessageText,
      events: events,
      resolvedSessionID: resolvedSessionID
    )
  }

  private static func decodeEvent(from line: String) throws -> CodexExecEvent {
    let object: CodexExecJSONValue

    do {
      object = try JSONDecoder().decode(CodexExecJSONDocument.self, from: Data(line.utf8)).value
    } catch {
      throw CodexExecError.malformedJSONL(line: line, partialObservation: nil)
    }

    guard case .object(let dictionary) = object else {
      return .unknown(type: "unknown", rawJSON: line)
    }

    let type = stringValue(forKey: "type", in: dictionary) ?? "unknown"

    switch type {
    case "thread.started":
      guard let threadID = stringValue(forKey: "thread_id", in: dictionary) else {
        return .unknown(type: type, rawJSON: line)
      }
      return .threadStarted(id: threadID)
    case "turn.started":
      return .turnStarted
    case "turn.completed":
      guard let usageDictionary = nestedDictionary(forKey: "usage", in: dictionary),
        let usage = usageValue(from: usageDictionary)
      else {
        return .unknown(type: type, rawJSON: line)
      }
      return .turnCompleted(usage: usage)
    case "turn.failed":
      guard let errorDictionary = nestedDictionary(forKey: "error", in: dictionary),
        let message = stringValue(forKey: "message", in: errorDictionary)
      else {
        return .unknown(type: type, rawJSON: line)
      }
      return .turnFailed(.init(message: message))
    case "item.started":
      guard let item = itemValue(forKey: "item", in: dictionary) else {
        return .unknown(type: type, rawJSON: line)
      }
      return .itemStarted(item)
    case "item.updated":
      guard let item = itemValue(forKey: "item", in: dictionary) else {
        return .unknown(type: type, rawJSON: line)
      }
      return .itemUpdated(item)
    case "item.completed":
      guard let item = itemValue(forKey: "item", in: dictionary) else {
        return .unknown(type: type, rawJSON: line)
      }
      return .itemCompleted(item)
    case "error":
      guard let message = stringValue(forKey: "message", in: dictionary) else {
        return .unknown(type: type, rawJSON: line)
      }
      return .error(.init(message: message))
    default:
      return .unknown(type: type, rawJSON: line)
    }
  }

  private static func itemValue(forKey key: String, in dictionary: [String: CodexExecJSONValue])
    -> CodexExecItem?
  {
    guard let itemDictionary = nestedDictionary(forKey: key, in: dictionary) else {
      return nil
    }

    let id = stringValue(forKey: "id", in: itemDictionary)
    let kind = stringValue(forKey: "type", in: itemDictionary) ?? "unknown"
    let rawJSON = rawJSONString(for: itemDictionary)

    switch kind {
    case "agent_message":
      guard let id, let text = stringValue(forKey: "text", in: itemDictionary) else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .agentMessage(.init(id: id, text: text))
    case "reasoning":
      guard let id, let text = stringValue(forKey: "text", in: itemDictionary) else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .reasoning(.init(id: id, text: text))
    case "command_execution":
      guard let id,
        let command = stringValue(forKey: "command", in: itemDictionary),
        let aggregatedOutput = stringValue(forKey: "aggregated_output", in: itemDictionary),
        let status = commandExecutionStatus(for: itemDictionary["status"])
      else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .commandExecution(
        .init(
          id: id,
          command: command,
          aggregatedOutput: aggregatedOutput,
          exitCode: intValue(for: itemDictionary["exit_code"]),
          status: status
        ))
    case "file_change":
      guard let id,
        let changesArray = objectArray(for: itemDictionary["changes"]),
        let status = patchApplyStatus(for: itemDictionary["status"])
      else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      let changes = changesArray.compactMap(fileUpdateChangeValue(from:))
      guard changes.count == changesArray.count else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .fileChange(.init(id: id, changes: changes, status: status))
    case "mcp_tool_call":
      guard let id,
        let server = stringValue(forKey: "server", in: itemDictionary),
        let tool = stringValue(forKey: "tool", in: itemDictionary),
        let status = mcpToolCallStatus(for: itemDictionary["status"])
      else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }

      let result: CodexExecItem.McpToolCallResult?
      if let resultDictionary = nestedDictionary(forKey: "result", in: itemDictionary) {
        let contentValues = arrayValue(for: resultDictionary["content"]) ?? []
        let structuredContent = resultDictionary["structured_content"] ?? .null
        result = .init(content: contentValues, structuredContent: structuredContent)
      } else {
        result = nil
      }

      let error: CodexExecItem.McpToolCallError?
      if let errorDictionary = nestedDictionary(forKey: "error", in: itemDictionary),
        let message = stringValue(forKey: "message", in: errorDictionary)
      {
        error = .init(message: message)
      } else {
        error = nil
      }

      return .mcpToolCall(
        .init(
          id: id,
          server: server,
          tool: tool,
          arguments: itemDictionary["arguments"] ?? .null,
          result: result,
          error: error,
          status: status
        ))
    case "web_search":
      guard let id,
        let query = stringValue(forKey: "query", in: itemDictionary),
        let action = webSearchAction(for: itemDictionary["action"])
      else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .webSearch(.init(id: id, query: query, action: action))
    case "todo_list":
      guard let id else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      let itemDictionaries = objectArray(for: itemDictionary["items"]) ?? []
      let items = itemDictionaries.compactMap(todoItemValue(from:))
      guard items.count == itemDictionaries.count else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .todoList(.init(id: id, items: items))
    case "error":
      guard let id, let message = stringValue(forKey: "message", in: itemDictionary) else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }
      return .error(.init(id: id, message: message))
    default:
      return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
    }
  }

  private static func usageValue(from dictionary: [String: CodexExecJSONValue]) -> CodexExecUsage? {
    guard let inputTokens = intValue(for: dictionary["input_tokens"]),
      let cachedInputTokens = intValue(for: dictionary["cached_input_tokens"]),
      let outputTokens = intValue(for: dictionary["output_tokens"])
    else {
      return nil
    }

    return CodexExecUsage(
      inputTokens: inputTokens,
      cachedInputTokens: cachedInputTokens,
      outputTokens: outputTokens
    )
  }

  private static func fileUpdateChangeValue(from dictionary: [String: CodexExecJSONValue])
    -> CodexExecItem
    .FileUpdateChange?
  {
    guard let path = stringValue(forKey: "path", in: dictionary),
      let kind = patchChangeKind(for: dictionary["kind"])
    else {
      return nil
    }

    return .init(path: path, kind: kind)
  }

  private static func todoItemValue(from dictionary: [String: CodexExecJSONValue]) -> CodexExecItem
    .TodoItem?
  {
    guard let text = stringValue(forKey: "text", in: dictionary),
      case .bool(let completed) = dictionary["completed"]
    else {
      return nil
    }

    return .init(text: text, completed: completed)
  }

  private static func commandExecutionStatus(for value: CodexExecJSONValue?)
    -> CodexExecCommandExecutionStatus?
  {
    guard case .string(let rawValue) = value else {
      return nil
    }
    return CodexExecCommandExecutionStatus(rawValue: rawValue)
  }

  private static func patchChangeKind(for value: CodexExecJSONValue?) -> CodexExecPatchChangeKind? {
    guard case .string(let rawValue) = value else {
      return nil
    }
    return CodexExecPatchChangeKind(rawValue: rawValue)
  }

  private static func patchApplyStatus(for value: CodexExecJSONValue?) -> CodexExecPatchApplyStatus?
  {
    guard case .string(let rawValue) = value else {
      return nil
    }
    return CodexExecPatchApplyStatus(rawValue: rawValue)
  }

  private static func mcpToolCallStatus(for value: CodexExecJSONValue?)
    -> CodexExecMcpToolCallStatus?
  {
    guard case .string(let rawValue) = value else {
      return nil
    }
    return CodexExecMcpToolCallStatus(rawValue: rawValue)
  }

  private static func webSearchAction(for value: CodexExecJSONValue?) -> CodexExecWebSearchAction? {
    guard let value else {
      return .other
    }

    if case .null = value {
      return .other
    }

    guard case .object(let dictionary) = value else {
      return .unknown(rawJSON: rawJSONString(for: value))
    }

    guard let type = stringValue(forKey: "type", in: dictionary) else {
      return .unknown(rawJSON: rawJSONString(for: value))
    }

    switch type {
    case "search":
      return .search(
        query: stringValue(forKey: "query", in: dictionary),
        queries: stringArray(for: dictionary["queries"]) ?? []
      )
    case "open_page":
      return .openPage(url: stringValue(forKey: "url", in: dictionary))
    case "find_in_page":
      return .findInPage(
        url: stringValue(forKey: "url", in: dictionary),
        pattern: stringValue(forKey: "pattern", in: dictionary)
      )
    case "other":
      return .other
    default:
      return .unknown(rawJSON: rawJSONString(for: value))
    }
  }

  private static func stringValue(
    forKey key: String, in dictionary: [String: CodexExecJSONValue]?
  ) -> String? {
    guard case .string(let value) = dictionary?[key] else { return nil }
    return value
  }

  private static func nestedDictionary(
    forKey key: String, in dictionary: [String: CodexExecJSONValue]
  ) -> [String: CodexExecJSONValue]? {
    guard case .object(let value) = dictionary[key] else { return nil }
    return value
  }

  private static func arrayValue(for value: CodexExecJSONValue?) -> [CodexExecJSONValue]? {
    guard case .array(let values) = value else { return nil }
    return values
  }

  private static func objectArray(
    for value: CodexExecJSONValue?
  ) -> [[String: CodexExecJSONValue]]? {
    guard let values = arrayValue(for: value) else { return nil }
    var objects: [[String: CodexExecJSONValue]] = []
    for value in values {
      guard case .object(let object) = value else { return nil }
      objects.append(object)
    }
    return objects
  }

  private static func stringArray(for value: CodexExecJSONValue?) -> [String]? {
    guard let values = arrayValue(for: value) else { return nil }
    var strings: [String] = []
    for value in values {
      guard case .string(let string) = value else { return nil }
      strings.append(string)
    }
    return strings
  }

  private static func intValue(for value: CodexExecJSONValue?) -> Int? {
    guard case .integer(let integer) = value else { return nil }
    return Int(exactly: integer)
  }

  private static func rawJSONString(for value: CodexExecJSONValue) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(CodexExecJSONDocument(value: value)) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func rawJSONString(for value: [String: CodexExecJSONValue]) -> String? {
    rawJSONString(for: .object(value))
  }

  private static func extractedFinalMessageText(from event: CodexExecEvent) -> String? {
    switch event {
    case .itemStarted(let item),
      .itemUpdated(let item),
      .itemCompleted(let item):
      if case .agentMessage(let agentMessage) = item {
        return agentMessage.text
      }
      return nil
    default:
      return nil
    }
  }
}
