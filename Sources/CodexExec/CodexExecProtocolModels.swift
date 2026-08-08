/// JSON-compatible value used by high-fidelity exec protocol payloads.
public indirect enum CodexExecJSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([CodexExecJSONValue])
  case object([String: CodexExecJSONValue])
}

/// Token usage reported by upstream turn completion events.
public struct CodexExecUsage: Equatable, Sendable {
  /// Number of input tokens reported by upstream.
  public var inputTokens: Int
  /// Number of cached input tokens reported by upstream.
  public var cachedInputTokens: Int
  /// Number of output tokens reported by upstream.
  public var outputTokens: Int

  /// Creates a usage value.
  public init(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
  }
}

/// Error payload reported by upstream thread or event failures.
public struct CodexExecThreadError: Error, Equatable, Sendable {
  /// Human-readable upstream error message.
  public var message: String

  /// Creates a thread error payload.
  public init(message: String) {
    self.message = message
  }
}

/// Status for upstream command execution items.
public enum CodexExecCommandExecutionStatus: String, Equatable, Sendable {
  case inProgress = "in_progress"
  case completed
  case failed
  case declined
}

/// Kind of file change reported by upstream patch items.
public enum CodexExecPatchChangeKind: String, Equatable, Sendable {
  case add
  case delete
  case update
}

/// Status for upstream patch-apply items.
public enum CodexExecPatchApplyStatus: String, Equatable, Sendable {
  case inProgress = "in_progress"
  case completed
  case failed
}

/// Status for upstream MCP tool-call items.
public enum CodexExecMcpToolCallStatus: String, Equatable, Sendable {
  case inProgress = "in_progress"
  case completed
  case failed
}

/// Web-search action reported by an upstream web-search item.
public enum CodexExecWebSearchAction: Equatable, Sendable {
  case search(query: String?, queries: [String])
  case openPage(url: String?)
  case findInPage(url: String?, pattern: String?)
  case other
  case unknown(rawJSON: String?)
}

/// Canonical item payload emitted by the upstream exec JSONL protocol.
public enum CodexExecItem: Equatable, Sendable {
  /// Stable item family, preserving unknown upstream kinds by string.
  public enum Kind: Equatable, Sendable {
    case agentMessage
    case reasoning
    case commandExecution
    case fileChange
    case mcpToolCall
    case webSearch
    case todoList
    case error
    case unknown(String)
  }

  /// Completed or streamed assistant message item.
  public struct AgentMessageItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Assistant message text.
    public var text: String

    /// Creates an assistant message item.
    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }
  }

  /// Reasoning text item.
  public struct ReasoningItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Reasoning text.
    public var text: String

    /// Creates a reasoning item.
    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }
  }

  /// Command execution item with complete upstream-visible payload.
  public struct CommandExecutionItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Command string executed by upstream.
    public var command: String
    /// Aggregated command output observed by upstream.
    public var aggregatedOutput: String
    /// Command exit code, when available.
    public var exitCode: Int?
    /// Current command execution status.
    public var status: CodexExecCommandExecutionStatus

    /// Creates a command execution item.
    public init(
      id: String,
      command: String,
      aggregatedOutput: String,
      exitCode: Int? = nil,
      status: CodexExecCommandExecutionStatus
    ) {
      self.id = id
      self.command = command
      self.aggregatedOutput = aggregatedOutput
      self.exitCode = exitCode
      self.status = status
    }
  }

  /// Single file change entry inside a patch item.
  public struct FileUpdateChange: Equatable, Sendable {
    /// Changed file path.
    public var path: String
    /// Kind of file change.
    public var kind: CodexExecPatchChangeKind

    /// Creates a file update change.
    public init(path: String, kind: CodexExecPatchChangeKind) {
      self.path = path
      self.kind = kind
    }
  }

  /// Patch or file-change item.
  public struct FileChangeItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// File changes reported by upstream.
    public var changes: [FileUpdateChange]
    /// Current patch application status.
    public var status: CodexExecPatchApplyStatus

    /// Creates a file-change item.
    public init(id: String, changes: [FileUpdateChange], status: CodexExecPatchApplyStatus) {
      self.id = id
      self.changes = changes
      self.status = status
    }
  }

  /// Result payload for an MCP tool-call item.
  public struct McpToolCallResult: Equatable, Sendable {
    /// Raw MCP content blocks.
    public var content: [CodexExecJSONValue]
    /// Optional raw MCP structured content.
    public var structuredContent: CodexExecJSONValue?

    /// Creates an MCP tool-call result payload.
    public init(
      content: [CodexExecJSONValue],
      structuredContent: CodexExecJSONValue? = nil
    ) {
      self.content = content
      self.structuredContent = structuredContent
    }
  }

  /// Error payload for an MCP tool-call item.
  public struct McpToolCallError: Equatable, Sendable {
    /// Human-readable MCP tool-call error message.
    public var message: String

    /// Creates an MCP tool-call error payload.
    public init(message: String) {
      self.message = message
    }
  }

  /// MCP tool-call item.
  public struct McpToolCallItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// MCP server name.
    public var server: String
    /// MCP tool name.
    public var tool: String
    /// Raw MCP tool arguments.
    public var arguments: CodexExecJSONValue
    /// MCP tool result, when available.
    public var result: McpToolCallResult?
    /// MCP tool error, when available.
    public var error: McpToolCallError?
    /// Current MCP tool-call status.
    public var status: CodexExecMcpToolCallStatus

    /// Creates an MCP tool-call item.
    public init(
      id: String,
      server: String,
      tool: String,
      arguments: CodexExecJSONValue,
      result: McpToolCallResult? = nil,
      error: McpToolCallError? = nil,
      status: CodexExecMcpToolCallStatus
    ) {
      self.id = id
      self.server = server
      self.tool = tool
      self.arguments = arguments
      self.result = result
      self.error = error
      self.status = status
    }
  }

  /// Web-search item.
  public struct WebSearchItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Primary web-search query text.
    public var query: String
    /// Web-search action details.
    public var action: CodexExecWebSearchAction

    /// Creates a web-search item.
    public init(id: String, query: String, action: CodexExecWebSearchAction) {
      self.id = id
      self.query = query
      self.action = action
    }
  }

  /// Single todo entry inside a todo-list item.
  public struct TodoItem: Equatable, Sendable {
    /// Todo text.
    public var text: String
    /// Whether the todo entry is complete.
    public var completed: Bool

    /// Creates a todo entry.
    public init(text: String, completed: Bool) {
      self.text = text
      self.completed = completed
    }
  }

  /// Todo-list item.
  public struct TodoListItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Todo entries.
    public var items: [TodoItem]

    /// Creates a todo-list item.
    public init(id: String, items: [TodoItem]) {
      self.id = id
      self.items = items
    }
  }

  /// Non-fatal error item emitted as part of an event stream.
  public struct ErrorItem: Equatable, Sendable {
    /// Upstream item identifier.
    public var id: String
    /// Human-readable error message.
    public var message: String

    /// Creates an error item.
    public init(id: String, message: String) {
      self.id = id
      self.message = message
    }
  }

  /// Forward-compatible item wrapper for unknown upstream item kinds.
  public struct UnknownItem: Equatable, Sendable {
    /// Upstream item identifier, if present.
    public var id: String?
    /// Raw upstream item kind.
    public var kind: String
    /// Raw item JSON, when it can be preserved.
    public var rawJSON: String?

    /// Creates an unknown item while preserving the raw kind and JSON when available.
    public init(id: String?, kind: String, rawJSON: String?) {
      self.id = id
      self.kind = kind
      self.rawJSON = rawJSON
    }
  }

  case agentMessage(AgentMessageItem)
  case reasoning(ReasoningItem)
  case commandExecution(CommandExecutionItem)
  case fileChange(FileChangeItem)
  case mcpToolCall(McpToolCallItem)
  case webSearch(WebSearchItem)
  case todoList(TodoListItem)
  case error(ErrorItem)
  case unknown(UnknownItem)

  /// Stable upstream item identifier, if present.
  public var id: String? {
    switch self {
    case .agentMessage(let item):
      item.id
    case .reasoning(let item):
      item.id
    case .commandExecution(let item):
      item.id
    case .fileChange(let item):
      item.id
    case .mcpToolCall(let item):
      item.id
    case .webSearch(let item):
      item.id
    case .todoList(let item):
      item.id
    case .error(let item):
      item.id
    case .unknown(let item):
      item.id
    }
  }

  /// Stable item family classification.
  public var kind: Kind {
    switch self {
    case .agentMessage:
      .agentMessage
    case .reasoning:
      .reasoning
    case .commandExecution:
      .commandExecution
    case .fileChange:
      .fileChange
    case .mcpToolCall:
      .mcpToolCall
    case .webSearch:
      .webSearch
    case .todoList:
      .todoList
    case .error:
      .error
    case .unknown(let item):
      .unknown(item.kind)
    }
  }

  /// Text convenience for message-like items.
  public var text: String? {
    switch self {
    case .agentMessage(let item):
      item.text
    case .reasoning(let item):
      item.text
    default:
      nil
    }
  }
}

/// Canonical event emitted by the upstream exec JSONL protocol.
public enum CodexExecEvent: Equatable, Sendable {
  case threadStarted(id: String)
  case turnStarted
  case turnCompleted(usage: CodexExecUsage)
  case turnFailed(CodexExecThreadError)
  case itemStarted(CodexExecItem)
  case itemUpdated(CodexExecItem)
  case itemCompleted(CodexExecItem)
  case error(CodexExecThreadError)
  case unknown(type: String, rawJSON: String?)
}
