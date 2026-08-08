/// Identity and requested MCP protocol version supplied by the embedding client.
public struct CodexMCPClientInfo: Equatable, Sendable {
  /// Stable product name reported to the MCP server.
  public let name: String
  /// Optional human-readable product title.
  public let title: String?
  /// Real embedding product version reported to the MCP server.
  public let version: String
  /// MCP protocol version requested during initialization.
  public let requestedProtocolVersion: String

  /// Creates an explicit MCP client identity and protocol request.
  public init(
    name: String,
    title: String? = nil,
    version: String,
    requestedProtocolVersion: String
  ) {
    precondition(!name.isEmpty, "MCP client name must not be empty")
    precondition(!version.isEmpty, "MCP client version must not be empty")
    precondition(!requestedProtocolVersion.isEmpty, "MCP protocol version must not be empty")
    self.name = name
    self.title = title
    self.version = version
    self.requestedProtocolVersion = requestedProtocolVersion
  }
}
