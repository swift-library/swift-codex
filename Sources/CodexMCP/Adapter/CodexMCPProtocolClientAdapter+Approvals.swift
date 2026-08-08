import Foundation
import MCP

extension CodexMCPProtocolClientAdapter {
  func handleElicitationRequest(_ params: MCP.Value) async throws -> CodexMCPApprovalResponse {
    let localParams = codexValue(from: params)
    guard
      let originatingRequestID = CodexMCPToolCallSupport.originatingRequestID(
        fromApprovalParams: localParams)
    else {
      throw CodexMCPError.approvalFlowFailure
    }

    guard
      let serverRequestID = approvalRequestIDsByOriginatingRequestID[originatingRequestID],
      let route = routes[originatingRequestID]
    else {
      await failToolRoutes(with: .approvalFlowFailure)
      throw CodexMCPError.approvalFlowFailure
    }

    let approvalRequest: CodexMCPApprovalRequest
    do {
      approvalRequest = try CodexMCPToolCallSupport.approvalRequest(
        serverRequestID: serverRequestID,
        params: localParams,
        originatingRequestID: originatingRequestID,
      )
    } catch {
      await failToolRoute(originatingRequestID, with: .approvalFlowFailure)
      throw CodexMCPError.approvalFlowFailure
    }

    let decision: CodexMCPApprovalDecision = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CodexMCPApprovalDecision, Error>) in
      guard approvalContinuations[serverRequestID] == nil else {
        continuation.resume(throwing: CodexMCPError.approvalFlowFailure)
        return
      }
      approvalContinuations[serverRequestID] = continuation
      Task {
        await route.approvalState.register(approvalRequest.requestID)
        await route.approvalRequestController.yield(approvalRequest)
      }
    }

    return .init(decision: decision.wireValue)
  }

  func resolveApprovalRequest(
    _ requestID: CodexMCPRequestID,
    decision: CodexMCPApprovalDecision
  ) throws {
    guard let continuation = approvalContinuations.removeValue(forKey: requestID) else {
      throw CodexMCPError.approvalFlowFailure
    }

    continuation.resume(returning: decision)
  }

  func resumeApprovalContinuation(
    forOriginatingRequestID requestID: CodexMCPRequestID,
    throwing error: Error
  ) {
    guard
      let approvalRequestID = approvalRequestIDsByOriginatingRequestID[requestID],
      let continuation = approvalContinuations.removeValue(forKey: approvalRequestID)
    else {
      return
    }

    continuation.resume(throwing: error)
  }
}

enum CodexMCPElicitationCreate: MCP.Method {
  static let name = "elicitation/create"
  typealias Parameters = MCP.Value
  typealias Result = CodexMCPApprovalResponse
}

struct CodexMCPApprovalResponse: Codable, Hashable, Sendable {
  let decision: String
}
