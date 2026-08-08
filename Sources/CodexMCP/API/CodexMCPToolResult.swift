/// Result returned by a Codex MCP tool call.
public struct CodexMCPToolResult: Equatable, Sendable {
  /// Codex thread id reported by the tool, if available.
  public let threadID: String?
  /// Text content aggregated from MCP content blocks.
  public let content: String
  /// Raw MCP content blocks returned by the tool.
  public let rawContentBlocks: [CodexMCPJSONValue]
  /// Raw structured content returned by the tool, if any.
  public let rawStructuredContent: CodexMCPJSONValue?
  /// Whether the upstream tool result was marked as an error.
  public let isError: Bool

  /// Creates a tool result.
  public init(
    threadID: String?,
    content: String,
    rawContentBlocks: [CodexMCPJSONValue],
    rawStructuredContent: CodexMCPJSONValue?,
    isError: Bool,
  ) {
    self.threadID = threadID
    self.content = content
    self.rawContentBlocks = rawContentBlocks
    self.rawStructuredContent = rawStructuredContent
    self.isError = isError
  }
}
