import Foundation

/// Launch configuration for the upstream `codex mcp-server` process.
public struct CodexMCPLaunchOptions: Equatable, Sendable {
  /// Optional path to a `codex` executable.
  public var executableURL: URL?
  /// Optional current directory for the launched process.
  public var currentDirectoryURL: URL?
  /// Environment entries supplied to the launched process.
  public var environment: [String: String]

  /// Creates launch options for a Codex MCP client.
  public init(
    executableURL: URL? = nil,
    currentDirectoryURL: URL? = nil,
    environment: [String: String] = [:],
  ) {
    self.executableURL = executableURL
    self.currentDirectoryURL = currentDirectoryURL
    self.environment = environment
  }
}
