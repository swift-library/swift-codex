import Foundation

extension CodexMCPClient {
  /// Requests cancellation for an in-flight MCP request.
  public func cancel(requestID: CodexMCPRequestID) async throws -> Bool {
    switch state {
    case .running, .stopping:
      break
    case .idle, .starting, .stopped, .failed:
      throw CodexMCPError.invalidStateTransition(operation: .cancel, from: state)
    }

    guard await requestCancellationState.beginCancellation(for: requestID) else {
      return false
    }

    guard let protocolAdapter else {
      await requestCancellationState.rollbackCancellation(for: requestID)
      return false
    }

    do {
      try await protocolAdapter.cancel(requestID: requestID)
      return true
    } catch {
      await requestCancellationState.rollbackCancellation(for: requestID)
      throw error
    }
  }

  /// Sends an MCP ping to the running Codex MCP server.
  public func ping() async throws {
    try await requireRunningProtocolAdapter(for: .ping).ping()
  }

  /// Lists tools exposed by the running Codex MCP server.
  public func listTools() async throws -> [CodexMCPToolDescriptor] {
    try await requireRunningProtocolAdapter(for: .listTools).listTools()
  }

  /// Calls the Codex MCP `codex` tool and returns a streaming call handle.
  public func runCodex(_ request: CodexMCPRunRequest) async throws -> CodexMCPCallHandle {
    let protocolAdapter = try requireRunningProtocolAdapter(for: .runCodex)
    let toolCall = try await protocolAdapter.callTool(
      name: "codex",
      arguments: CodexMCPRunCodex.arguments(from: request),
    )
    await requestCancellationState.register(toolCall.requestID)

    let cancellationRequester: @Sendable (CodexMCPRequestID) async throws -> Bool = {
      [client = self] requestID in
      try await client.cancel(requestID: requestID)
    }
    let resultTask = completionTrackingTask(
      toolCall.resultTask,
      requestID: toolCall.requestID,
    )

    return CodexMCPCallHandle(
      requestID: toolCall.requestID,
      resultTask: resultTask,
      serverMessages: toolCall.serverMessages,
      approvalRequests: toolCall.approvalRequests,
      approvalResponder: toolCall.approvalResponder,
      cancellationRequester: cancellationRequester,
      approvalState: toolCall.approvalState,
    )
  }

  /// Calls the Codex MCP `codex-reply` tool for an existing thread.
  public func reply(_ request: CodexMCPReplyRequest) async throws -> CodexMCPCallHandle {
    let protocolAdapter = try requireRunningProtocolAdapter(for: .reply)
    let toolCall = try await protocolAdapter.callTool(
      name: "codex-reply",
      arguments: CodexMCPReply.arguments(from: request),
    )
    await requestCancellationState.register(toolCall.requestID)

    let cancellationRequester: @Sendable (CodexMCPRequestID) async throws -> Bool = {
      [client = self] requestID in
      try await client.cancel(requestID: requestID)
    }
    let resultTask = completionTrackingTask(
      Task {
        let result = try await toolCall.resultTask.value
        guard result.isError || result.threadID == request.threadID else {
          throw CodexMCPError.protocolFailure
        }
        return result
      },
      requestID: toolCall.requestID,
    )

    return CodexMCPCallHandle(
      requestID: toolCall.requestID,
      resultTask: resultTask,
      serverMessages: toolCall.serverMessages,
      approvalRequests: toolCall.approvalRequests,
      approvalResponder: toolCall.approvalResponder,
      cancellationRequester: cancellationRequester,
      approvalState: toolCall.approvalState,
    )
  }

  internal func writeTransportLine(_ line: String) async throws {
    throw CodexMCPError.transportFailure
  }

  internal func readTransportLine() async throws -> String? {
    throw CodexMCPError.transportFailure
  }
}

extension CodexMCPClient {
  func completionTrackingTask(
    _ task: Task<CodexMCPToolResult, Error>,
    requestID: CodexMCPRequestID
  ) -> Task<CodexMCPToolResult, Error> {
    Task {
      do {
        let result = try await task.value
        await requestCancellationState.complete(requestID)
        return result
      } catch {
        await requestCancellationState.complete(requestID)
        throw error
      }
    }
  }

  func requireRunningProtocolAdapter(
    for operation: CodexMCPError.LifecycleOperation
  ) throws -> CodexMCPProtocolClientAdapter {
    switch state {
    case .running:
      break
    case .idle, .starting, .stopping, .stopped, .failed:
      throw CodexMCPError.invalidStateTransition(operation: operation, from: state)
    }

    guard let protocolAdapter else {
      throw CodexMCPError.transportFailure
    }

    return protocolAdapter
  }
}
