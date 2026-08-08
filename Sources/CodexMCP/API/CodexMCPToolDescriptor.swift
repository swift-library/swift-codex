import Foundation

/// Tool descriptor returned by the upstream Codex MCP server.
public struct CodexMCPToolDescriptor: Equatable, Sendable {
  /// Tool name used for MCP `tools/call`.
  public let name: String
  /// Optional display title.
  public let title: String?
  /// Optional tool description.
  public let description: String?
  /// Raw JSON schema for tool input.
  public let inputSchema: [String: CodexMCPJSONValue]
  /// Raw JSON schema for tool output, if provided.
  public let outputSchema: [String: CodexMCPJSONValue]?

  /// Creates a tool descriptor.
  public init(
    name: String,
    title: String? = nil,
    description: String? = nil,
    inputSchema: [String: CodexMCPJSONValue],
    outputSchema: [String: CodexMCPJSONValue]? = nil,
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
  }
}
