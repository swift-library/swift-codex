import Foundation

/// Approval request emitted by Codex while a tool call is running.
public enum CodexMCPApprovalRequest: Equatable, Sendable {
  /// Command execution approval request.
  case exec(CodexMCPExecApprovalRequest)
  /// Patch application approval request.
  case patch(CodexMCPPatchApprovalRequest)

  /// MCP request id of the approval request itself.
  public var requestID: CodexMCPRequestID {
    switch self {
    case .exec(let request):
      return request.requestID
    case .patch(let request):
      return request.requestID
    }
  }

  /// Tool-call request id that originated this approval request.
  public var originatingRequestID: CodexMCPRequestID {
    switch self {
    case .exec(let request):
      return request.originatingRequestID
    case .patch(let request):
      return request.originatingRequestID
    }
  }

  /// Codex thread id associated with the request.
  public var threadID: String {
    switch self {
    case .exec(let request):
      return request.threadID
    case .patch(let request):
      return request.threadID
    }
  }

  /// Upstream Codex event id associated with the request.
  public var codexEventID: String {
    switch self {
    case .exec(let request):
      return request.codexEventID
    case .patch(let request):
      return request.codexEventID
    }
  }
}

/// Command execution approval payload.
public struct CodexMCPExecApprovalRequest: Equatable, Sendable {
  /// MCP request id of the approval request itself.
  public let requestID: CodexMCPRequestID
  /// Tool-call request id that originated this approval request.
  public let originatingRequestID: CodexMCPRequestID
  /// Codex thread id associated with the approval request.
  public let threadID: String
  /// Human-readable approval message.
  public let message: String
  /// Raw schema requested by the upstream approval flow.
  public let requestedSchema: CodexMCPJSONValue
  /// Upstream Codex event id associated with this request.
  public let codexEventID: String
  /// Command argv requested by upstream.
  public let command: [String]
  /// Working directory for the command.
  public let cwd: String
  /// Parsed command metadata, when provided by upstream.
  public let parsedCommand: [CodexMCPJSONValue]?
}

/// Patch application approval payload.
public struct CodexMCPPatchApprovalRequest: Equatable, Sendable {
  /// MCP request id of the approval request itself.
  public let requestID: CodexMCPRequestID
  /// Tool-call request id that originated this approval request.
  public let originatingRequestID: CodexMCPRequestID
  /// Codex thread id associated with the approval request.
  public let threadID: String
  /// Human-readable approval message.
  public let message: String
  /// Raw schema requested by the upstream approval flow.
  public let requestedSchema: CodexMCPJSONValue
  /// Upstream Codex event id associated with this request.
  public let codexEventID: String
  /// Optional upstream patch reason.
  public let reason: String?
  /// Optional root that would be granted by approval.
  public let grantRoot: String?
  /// Raw patch change map.
  public let changes: [String: CodexMCPJSONValue]
}

/// Decision sent back for a pending Codex approval request.
public enum CodexMCPApprovalDecision: String, Equatable, Sendable {
  case allow
  case deny

  internal var wireValue: String {
    switch self {
    case .allow:
      return "approved"
    case .deny:
      return "denied"
    }
  }
}
