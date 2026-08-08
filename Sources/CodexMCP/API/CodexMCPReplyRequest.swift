import Foundation

/// Request for the Codex MCP `codex-reply` tool.
public struct CodexMCPReplyRequest: Equatable, Sendable {
  /// Thread id to continue.
  public var threadID: String
  /// Reply prompt to send to the thread.
  public var prompt: String

  /// Creates a reply request.
  public init(
    threadID: String,
    prompt: String,
  ) {
    self.threadID = threadID
    self.prompt = prompt
  }
}
