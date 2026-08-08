import Foundation
import MCP

extension CodexMCPProtocolClientAdapter {
  func observeInboundData(_ data: Data) async {
    guard
      let envelope = try? JSONDecoder().decode(CodexMCPJSONValue.self, from: data),
      case .object(let object) = envelope
    else {
      return
    }

    if object["method"] == nil, object["id"] != nil {
      guard let responseID = requestID(from: object["id"]) else {
        await recordProtocolFailureAndDisconnect()
        return
      }

      if let failure = jsonRPCFailure(from: object["error"]) {
        jsonRPCFailures[responseID] = failure
        if !didInitialize {
          return
        }
      }

      if object["result"]?.objectValue?["protocolVersion"] != nil {
        initializeUserAgent =
          object["result"]?
          .objectValue?["serverInfo"]?
          .objectValue?["user_agent"]?
          .stringValue
        return
      }

      guard activeRequestIDs.contains(responseID) else {
        await recordProtocolFailureAndDisconnect()
        return
      }
      return
    }

    guard
      object["method"]?.stringValue == CodexMCPElicitationCreate.name,
      let serverRequestID = requestID(from: object["id"]),
      let params = object["params"],
      let originatingRequestID = CodexMCPToolCallSupport.originatingRequestID(
        fromApprovalParams: params)
    else {
      return
    }

    guard
      approvalRequestIDsByOriginatingRequestID[originatingRequestID] == nil,
      !approvalRequestIDsByOriginatingRequestID.values.contains(serverRequestID),
      approvalContinuations[serverRequestID] == nil
    else {
      await recordProtocolFailureAndDisconnect()
      return
    }
    approvalRequestIDsByOriginatingRequestID[originatingRequestID] = serverRequestID
  }

  private func recordProtocolFailureAndDisconnect() async {
    observedProtocolFailure = .protocolFailure
    await disconnectAfterProtocolFailure()
  }

  private func jsonRPCFailure(from value: CodexMCPJSONValue?) -> CodexMCPJSONRPCFailure? {
    guard
      let object = value?.objectValue,
      case .integer(let codeValue) = object["code"],
      let code = Int(exactly: codeValue),
      let message = object["message"]?.stringValue
    else {
      return nil
    }
    return .init(code: code, message: message, data: object["data"])
  }

  func disconnectAfterProtocolFailure() async {
    await client.disconnect()
    await transport.disconnect()
  }

  func handleTransportClose(_ error: CodexMCPError) async {
    if observedProtocolFailure == nil {
      observedProtocolFailure = error
    }
    for requestID in Array(routes.keys) {
      routeFailures[requestID] = error
      await finishRoute(requestID, error: error)
    }
    await client.disconnect()
  }

  func handleEventNotification(_ message: MCP.Message<CodexMCPEventNotification>) async {
    do {
      let localParams = codexValue(from: message.params)
      guard
        let serverMessage = try CodexMCPToolCallSupport.serverMessage(
          method: message.method,
          params: localParams,
        ),
        let requestID = serverMessage.requestID,
        let route = routes[requestID]
      else {
        return
      }

      await route.serverMessageController.yield(serverMessage)
    } catch {
      return
    }
  }
}

struct CodexMCPEventNotification: MCP.Notification {
  static let name = "codex/event"
  typealias Parameters = MCP.Value
}
