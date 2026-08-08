/// Error values surfaced by the Codex MCP client facade.
public enum CodexMCPError: Error, Equatable, Sendable {
  case invalidStateTransition(
    operation: LifecycleOperation,
    from: CodexMCPClientState,
  )
  case startupFailure
  case transportFailure
  case protocolFailure
  /// JSON-RPC error with its complete protocol diagnostics.
  case jsonrpcFailure(CodexMCPJSONRPCFailure)
  /// Process or transport failure with bounded, redacted diagnostics.
  case processFailure(stage: ProcessFailureStage, context: CodexMCPFailureContext)
  case approvalFlowFailure

  /// Stage at which an owned MCP subprocess failed.
  public enum ProcessFailureStage: String, Equatable, Sendable {
    case launch
    case startup
    case transport
    case stop
  }

  /// Operation that failed due to lifecycle or protocol state.
  public enum LifecycleOperation: String, Equatable, Sendable {
    case start
    case stop
    case cancel
    case ping
    case listTools
    case runCodex
    case reply
  }
}

/// Complete JSON-RPC error information retained at the public boundary.
public struct CodexMCPJSONRPCFailure: Equatable, Sendable {
  public let code: Int
  public let message: String
  public let data: CodexMCPJSONValue?

  public init(code: Int, message: String, data: CodexMCPJSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

/// Bounded diagnostic context for failures involving the owned subprocess.
public struct CodexMCPFailureContext: Equatable, Sendable {
  public let message: String?
  public let stderr: String?

  public init(message: String? = nil, stderr: String? = nil) {
    self.message = message
    self.stderr = stderr
  }
}
