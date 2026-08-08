import Foundation

/// Handle for an in-flight Codex MCP tool call.
public final class CodexMCPCallHandle: @unchecked Sendable {
  /// MCP request id associated with the tool call.
  public let requestID: CodexMCPRequestID
  /// Codex-specific server messages routed to this call.
  public let serverMessages: AsyncStream<CodexMCPServerMessage>
  /// Approval requests that must be answered before the call can continue.
  public let approvalRequests: AsyncStream<CodexMCPApprovalRequest>

  private let resultTask: Task<CodexMCPToolResult, Error>
  private let approvalResponder:
    @Sendable (CodexMCPRequestID, CodexMCPApprovalDecision) async throws -> Void
  private let cancellationRequester: @Sendable (CodexMCPRequestID) async throws -> Bool
  private let approvalState: CodexMCPApprovalState

  internal init(
    requestID: CodexMCPRequestID,
    resultTask: Task<CodexMCPToolResult, Error>,
    serverMessages: AsyncStream<CodexMCPServerMessage>,
    approvalRequests: AsyncStream<CodexMCPApprovalRequest>,
    approvalResponder:
      @escaping @Sendable (CodexMCPRequestID, CodexMCPApprovalDecision) async throws -> Void,
    cancellationRequester: @escaping @Sendable (CodexMCPRequestID) async throws -> Bool,
    approvalState: CodexMCPApprovalState,
  ) {
    self.requestID = requestID
    self.resultTask = resultTask
    self.serverMessages = serverMessages
    self.approvalRequests = approvalRequests
    self.approvalResponder = approvalResponder
    self.cancellationRequester = cancellationRequester
    self.approvalState = approvalState
  }

  /// Waits for the tool call result.
  public func value() async throws -> CodexMCPToolResult {
    try await resultTask.value
  }

  /// Requests cancellation for this in-flight tool call.
  public func cancel() async throws -> Bool {
    try await cancellationRequester(requestID)
  }

  /// Responds to a pending approval request for this call.
  public func respond(
    to approvalRequestID: CodexMCPRequestID,
    with decision: CodexMCPApprovalDecision,
  ) async throws {
    guard await approvalState.consume(approvalRequestID) else {
      throw CodexMCPError.approvalFlowFailure
    }

    try await approvalResponder(approvalRequestID, decision)
  }

  internal func registerApprovalRequest(_ approvalRequest: CodexMCPApprovalRequest) async {
    await approvalState.register(approvalRequest.requestID)
  }

  internal func finishApprovalRequests() async {
    await approvalState.close()
  }
}
