/// Codex-specific server notification routed from the MCP event stream.
public struct CodexMCPServerMessage: Equatable, Sendable {
  /// MCP notification method name.
  public let method: String
  /// Raw notification payload.
  public let rawEvent: CodexMCPJSONValue
  /// Associated tool-call request id, if present.
  public let requestID: CodexMCPRequestID?
  /// Associated Codex thread id, if present.
  public let threadID: String?

  /// Creates a routed server message.
  public init(
    method: String,
    rawEvent: CodexMCPJSONValue,
    requestID: CodexMCPRequestID?,
    threadID: String?,
  ) {
    self.method = method
    self.rawEvent = rawEvent
    self.requestID = requestID
    self.threadID = threadID
  }
}
