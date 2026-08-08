import Foundation
import MCP

internal struct CodexMCPAdapterToolCall: Sendable {
  let requestID: CodexMCPRequestID
  let resultTask: Task<CodexMCPToolResult, Error>
  let serverMessages: AsyncStream<CodexMCPServerMessage>
  let approvalRequests: AsyncStream<CodexMCPApprovalRequest>
  let approvalResponder:
    @Sendable (CodexMCPRequestID, CodexMCPApprovalDecision) async throws -> Void
  let approvalState: CodexMCPApprovalState
}

internal actor CodexMCPProtocolClientAdapter {
  let client: MCP.Client
  let transport: CodexMCPProcessTransport
  let requestedProtocolVersion: String
  var nextRequestNumber: Int64 = 1
  var routes: [CodexMCPRequestID: ToolCallRoute] = [:]
  var activeRequestIDs: Set<CodexMCPRequestID> = []
  var observedProtocolFailure: CodexMCPError?
  var jsonRPCFailures: [CodexMCPRequestID: CodexMCPJSONRPCFailure] = [:]
  var didInitialize = false
  var initializeUserAgent: String?
  var routeFailures: [CodexMCPRequestID: CodexMCPError] = [:]
  var approvalRequestIDsByOriginatingRequestID: [CodexMCPRequestID: CodexMCPRequestID] = [:]
  var approvalContinuations:
    [CodexMCPRequestID: CheckedContinuation<CodexMCPApprovalDecision, Error>] = [:]

  init(transport: CodexMCPProcessTransport, clientInfo: CodexMCPClientInfo) {
    self.transport = transport
    requestedProtocolVersion = clientInfo.requestedProtocolVersion
    client = MCP.Client(
      name: clientInfo.name,
      version: clientInfo.version,
      title: clientInfo.title,
      capabilities: .init(
        elicitation: .init(
          form: .init()
        )
      ),
      configuration: .default,
    )
  }

  static func make(
    subprocess: CodexMCPManagedSubprocess,
    clientInfo: CodexMCPClientInfo
  ) throws -> Self {
    let transport = try CodexMCPProcessTransport.make(
      subprocess: subprocess,
      requestedProtocolVersion: clientInfo.requestedProtocolVersion
    )
    return Self(transport: transport, clientInfo: clientInfo)
  }

  func start() async throws -> CodexMCPStartupMetadata {
    await transport.setInboundObserver { [weak self] data in
      await self?.observeInboundData(data)
    }
    await transport.setCloseObserver { [weak self] error in
      await self?.handleTransportClose(error)
    }

    await client.onNotification(CodexMCPEventNotification.self) { [weak self] message in
      await self?.handleEventNotification(message)
    }

    await client.withMethodHandler(CodexMCPElicitationCreate.self) { [weak self] params in
      guard let self else {
        throw CodexMCPError.approvalFlowFailure
      }

      return try await self.handleElicitationRequest(params)
    }

    do {
      let result = try await client.connect(transport: transport)
      guard result.protocolVersion == requestedProtocolVersion else {
        throw CodexMCPError.protocolFailure
      }
      didInitialize = true
      return CodexMCPStartupMetadata(
        protocolVersion: result.protocolVersion,
        serverInfo: .init(
          name: result.serverInfo.name,
          title: result.serverInfo.title,
          version: result.serverInfo.version,
          userAgent: initializeUserAgent,
        ),
      )
    } catch let error as CodexMCPError {
      throw error
    } catch {
      throw consumeObservedProtocolFailure() ?? mapMCPError(error, fallback: .startupFailure)
    }
  }

  func stop() async {
    await client.disconnect()
    await transport.disconnect()
    await failAllRoutes(with: CodexMCPError.transportFailure)
  }

  func ping() async throws {
    try await withTrackedRequest { _, mcpRequestID in
      let context = try await client.send(MCP.Ping.request(id: mcpRequestID))
      _ = try await context.value
    }
  }

  func listTools() async throws -> [CodexMCPToolDescriptor] {
    try await withTrackedRequest { _, mcpRequestID in
      let context = try await client.send(
        MCP.ListTools.request(
          id: mcpRequestID,
          .init(),
        ))
      let result = try await context.value
      return try result.tools.map(toolDescriptor(from:))
    }
  }

  func cancel(requestID: CodexMCPRequestID) async throws {
    do {
      try await client.notify(
        MCP.CancelledNotification.message(
          .init(requestId: mcpID(from: requestID))
        )
      )
    } catch {
      throw mapMCPError(error, fallback: .transportFailure)
    }
  }

  func allocateRequestID() throws -> CodexMCPRequestID {
    let requestID = CodexMCPRequestID.integer(nextRequestNumber)
    guard !activeRequestIDs.contains(requestID), nextRequestNumber < Int64.max else {
      throw CodexMCPError.protocolFailure
    }
    nextRequestNumber += 1
    return requestID
  }

  func withTrackedRequest<Result>(
    _ body: (CodexMCPRequestID, MCP.ID) async throws -> Result
  ) async throws -> Result {
    let requestID = try allocateRequestID()
    activeRequestIDs.insert(requestID)
    defer {
      activeRequestIDs.remove(requestID)
    }

    do {
      return try await body(requestID, mcpID(from: requestID))
    } catch {
      throw consumeJSONRPCFailure(for: requestID) ?? consumeObservedProtocolFailure()
        ?? mapMCPError(error, fallback: .protocolFailure)
    }
  }

  func mappedError(
    for requestID: CodexMCPRequestID,
    _ error: Error,
    fallback: CodexMCPError
  ) -> CodexMCPError {
    consumeJSONRPCFailure(for: requestID) ?? consumeRouteFailure(for: requestID)
      ?? consumeObservedProtocolFailure()
      ?? mapMCPError(error, fallback: fallback)
  }

  func consumeObservedProtocolFailure() -> CodexMCPError? {
    defer {
      observedProtocolFailure = nil
    }
    return observedProtocolFailure
  }

  func consumeRouteFailure(for requestID: CodexMCPRequestID) -> CodexMCPError? {
    routeFailures.removeValue(forKey: requestID)
  }

  func consumeJSONRPCFailure(for requestID: CodexMCPRequestID) -> CodexMCPError? {
    jsonRPCFailures.removeValue(forKey: requestID).map(CodexMCPError.jsonrpcFailure)
  }
}
