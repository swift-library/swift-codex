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
    let object: Any

    do {
      object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    } catch {
      throw CodexExecError.malformedJSONL(line: line, partialObservation: nil)
    }

    guard let dictionary = object as? [String: Any] else {
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

  private static func itemValue(forKey key: String, in dictionary: [String: Any]) -> CodexExecItem?
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
        let changesArray = itemDictionary["changes"] as? [[String: Any]],
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
        let status = mcpToolCallStatus(for: itemDictionary["status"]),
        let arguments = jsonValue(for: itemDictionary["arguments"] ?? NSNull())
      else {
        return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
      }

      let result: CodexExecItem.McpToolCallResult?
      if let resultDictionary = nestedDictionary(forKey: "result", in: itemDictionary) {
        let contentValues = (resultDictionary["content"] as? [Any] ?? []).compactMap(
          jsonValue(for:))
        guard contentValues.count == (resultDictionary["content"] as? [Any] ?? []).count else {
          return .unknown(.init(id: id, kind: kind, rawJSON: rawJSON))
        }
        let structuredContent = jsonValue(for: resultDictionary["structured_content"] ?? NSNull())
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
          arguments: arguments,
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
      let items = (itemDictionary["items"] as? [[String: Any]] ?? []).compactMap(
        todoItemValue(from:))
      guard items.count == (itemDictionary["items"] as? [[String: Any]] ?? []).count else {
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

  private static func usageValue(from dictionary: [String: Any]) -> CodexExecUsage? {
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

  private static func fileUpdateChangeValue(from dictionary: [String: Any]) -> CodexExecItem
    .FileUpdateChange?
  {
    guard let path = stringValue(forKey: "path", in: dictionary),
      let kind = patchChangeKind(for: dictionary["kind"])
    else {
      return nil
    }

    return .init(path: path, kind: kind)
  }

  private static func todoItemValue(from dictionary: [String: Any]) -> CodexExecItem.TodoItem? {
    guard let text = stringValue(forKey: "text", in: dictionary),
      let completed = dictionary["completed"] as? Bool
    else {
      return nil
    }

    return .init(text: text, completed: completed)
  }

  private static func commandExecutionStatus(for value: Any?) -> CodexExecCommandExecutionStatus? {
    guard let rawValue = value as? String else {
      return nil
    }
    return CodexExecCommandExecutionStatus(rawValue: rawValue)
  }

  private static func patchChangeKind(for value: Any?) -> CodexExecPatchChangeKind? {
    guard let rawValue = value as? String else {
      return nil
    }
    return CodexExecPatchChangeKind(rawValue: rawValue)
  }

  private static func patchApplyStatus(for value: Any?) -> CodexExecPatchApplyStatus? {
    guard let rawValue = value as? String else {
      return nil
    }
    return CodexExecPatchApplyStatus(rawValue: rawValue)
  }

  private static func mcpToolCallStatus(for value: Any?) -> CodexExecMcpToolCallStatus? {
    guard let rawValue = value as? String else {
      return nil
    }
    return CodexExecMcpToolCallStatus(rawValue: rawValue)
  }

  private static func webSearchAction(for value: Any?) -> CodexExecWebSearchAction? {
    guard let value else {
      return .other
    }

    if value is NSNull {
      return .other
    }

    guard let dictionary = value as? [String: Any] else {
      return .unknown(rawJSON: rawJSONString(for: value))
    }

    guard let type = stringValue(forKey: "type", in: dictionary) else {
      return .unknown(rawJSON: rawJSONString(for: value))
    }

    switch type {
    case "search":
      return .search(
        query: stringValue(forKey: "query", in: dictionary),
        queries: dictionary["queries"] as? [String] ?? []
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

  private static func stringValue(forKey key: String, in dictionary: [String: Any]?) -> String? {
    dictionary?[key] as? String
  }

  private static func nestedDictionary(forKey key: String, in dictionary: [String: Any]) -> [String:
    Any]?
  {
    dictionary[key] as? [String: Any]
  }

  private static func intValue(for value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    return nil
  }

  private static func jsonValue(for value: Any) -> CodexExecJSONValue? {
    switch value {
    case is NSNull:
      return .null
    case let bool as Bool:
      return .bool(bool)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      switch String(cString: number.objCType) {
      case "f", "d":
        return .double(number.doubleValue)
      default:
        guard let integer = Int64(number.stringValue) else {
          return nil
        }
        return .integer(integer)
      }
    case let string as String:
      return .string(string)
    case let array as [Any]:
      let values = array.compactMap(jsonValue(for:))
      guard values.count == array.count else {
        return nil
      }
      return .array(values)
    case let dictionary as [String: Any]:
      var result: [String: CodexExecJSONValue] = [:]
      for (key, child) in dictionary {
        guard let value = jsonValue(for: child) else {
          return nil
        }
        result[key] = value
      }
      return .object(result)
    default:
      return nil
    }
  }

  private static func rawJSONString(for value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value) else {
      return nil
    }

    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else {
      return nil
    }

    return String(data: data, encoding: .utf8)
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
