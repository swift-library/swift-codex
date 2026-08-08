import Foundation
import MCP

extension CodexMCPProtocolClientAdapter {
  func callTool<Arguments: Codable>(
    name: String,
    arguments: Arguments
  ) async throws -> CodexMCPAdapterToolCall {
    let requestID = try allocateRequestID()
    let mcpRequestID = mcpID(from: requestID)
    let argumentObject = try mcpArgumentObject(from: arguments)
    let route = ToolCallRoute.make()
    routes[requestID] = route
    activeRequestIDs.insert(requestID)

    let context: MCP.RequestContext<MCP.Value>
    do {
      context = try await client.send(
        CodexMCPRawCallTool.request(
          id: mcpRequestID,
          .init(name: name, arguments: argumentObject),
        )
      )
    } catch {
      routes.removeValue(forKey: requestID)
      activeRequestIDs.remove(requestID)
      throw consumeJSONRPCFailure(for: requestID)
        ?? mapMCPError(error, fallback: .protocolFailure)
    }

    let resultTask = Task { [weak self] in
      do {
        let value = try await context.value
        let result = try CodexMCPToolCallSupport.toolResult(from: codexValue(from: value))
        await self?.finishRoute(requestID, error: nil)
        return result
      } catch {
        let mappedError =
          await self?.mappedError(
            for: requestID,
            error,
            fallback: .protocolFailure,
          ) ?? mapMCPError(error, fallback: .protocolFailure)
        await self?.finishRoute(requestID, error: mappedError)
        throw mappedError
      }
    }

    return CodexMCPAdapterToolCall(
      requestID: requestID,
      resultTask: resultTask,
      serverMessages: route.serverMessages,
      approvalRequests: route.approvalRequests,
      approvalResponder: { [weak self] approvalRequestID, decision in
        guard let self else {
          throw CodexMCPError.approvalFlowFailure
        }

        try await self.resolveApprovalRequest(approvalRequestID, decision: decision)
      },
      approvalState: route.approvalState,
    )
  }

  func finishRoute(_ requestID: CodexMCPRequestID, error: Error?) async {
    guard let route = routes.removeValue(forKey: requestID) else {
      return
    }
    activeRequestIDs.remove(requestID)

    if let error {
      resumeApprovalContinuation(forOriginatingRequestID: requestID, throwing: error)
    } else {
      resumeApprovalContinuation(
        forOriginatingRequestID: requestID, throwing: CodexMCPError.approvalFlowFailure)
    }

    approvalRequestIDsByOriginatingRequestID.removeValue(forKey: requestID)

    await route.serverMessageController.finish()
    await route.approvalRequestController.finish()
    await route.approvalState.close()
  }

  func failAllRoutes(with error: CodexMCPError) async {
    for continuation in approvalContinuations.values {
      continuation.resume(throwing: error)
    }
    approvalContinuations.removeAll(keepingCapacity: false)

    for requestID in Array(routes.keys) {
      await finishRoute(requestID, error: error)
    }
    routes.removeAll(keepingCapacity: false)
    approvalRequestIDsByOriginatingRequestID.removeAll(keepingCapacity: false)
    activeRequestIDs.removeAll(keepingCapacity: false)
  }

  func failToolRoutes(with error: CodexMCPError) async {
    for requestID in Array(routes.keys) {
      await failToolRoute(requestID, with: error)
    }
    Task { [weak self] in
      await self?.disconnectAfterProtocolFailure()
    }
  }

  func failToolRoute(_ requestID: CodexMCPRequestID, with error: CodexMCPError) async {
    routeFailures[requestID] = error
    await finishRoute(requestID, error: error)
  }
}

struct ToolCallRoute: Sendable {
  let serverMessages: AsyncStream<CodexMCPServerMessage>
  let serverMessageController: CodexMCPServerMessageStreamController
  let approvalRequests: AsyncStream<CodexMCPApprovalRequest>
  let approvalRequestController: CodexMCPApprovalRequestStreamController
  let approvalState: CodexMCPApprovalState

  static func make() -> Self {
    let (serverMessages, serverMessageController) =
      CodexMCPServerMessageStreamController.makeStream()
    let (approvalRequests, approvalRequestController) =
      CodexMCPApprovalRequestStreamController.makeStream()
    return Self(
      serverMessages: serverMessages,
      serverMessageController: serverMessageController,
      approvalRequests: approvalRequests,
      approvalRequestController: approvalRequestController,
      approvalState: CodexMCPApprovalState(),
    )
  }
}

enum CodexMCPRawCallTool: MCP.Method {
  static let name = "tools/call"
  typealias Parameters = MCP.CallTool.Parameters
  typealias Result = MCP.Value
}
