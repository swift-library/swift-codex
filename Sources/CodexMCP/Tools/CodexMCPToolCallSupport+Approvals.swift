import Foundation

extension CodexMCPToolCallSupport {
  static func approvalRequest(
    serverRequestID: CodexMCPRequestID,
    params: CodexMCPJSONValue,
    originatingRequestID: CodexMCPRequestID
  ) throws -> CodexMCPApprovalRequest {
    guard let paramsObject = params.objectValue else {
      throw CodexMCPError.approvalFlowFailure
    }

    let message = paramsObject["message"]?.stringValue
    let requestedSchema = paramsObject["requestedSchema"]
    let threadID = paramsObject["threadId"]?.stringValue
    let elicitation = paramsObject["codex_elicitation"]?.stringValue
    let toolCallID = paramsObject["codex_mcp_tool_call_id"]?.stringValue
    let codexEventID = paramsObject["codex_event_id"]?.stringValue

    guard
      let message,
      let requestedSchema,
      let threadID,
      let elicitation,
      let toolCallID,
      let codexEventID
    else {
      throw CodexMCPError.approvalFlowFailure
    }

    guard originatingRequestID == requestIDValue(fromToolCallID: toolCallID) else {
      throw CodexMCPError.approvalFlowFailure
    }

    switch elicitation {
    case "exec-approval":
      guard
        let commandArray = paramsObject["codex_command"]?.arrayValue,
        let command = stringArray(from: commandArray),
        let cwd = paramsObject["codex_cwd"]?.stringValue
      else {
        throw CodexMCPError.approvalFlowFailure
      }

      let parsedCommand = paramsObject["codex_parsed_cmd"]?.arrayValue
      return .exec(
        .init(
          requestID: serverRequestID,
          originatingRequestID: originatingRequestID,
          threadID: threadID,
          message: message,
          requestedSchema: requestedSchema,
          codexEventID: codexEventID,
          command: command,
          cwd: cwd,
          parsedCommand: parsedCommand,
        ))
    case "patch-approval":
      guard let changes = paramsObject["codex_changes"]?.objectValue else {
        throw CodexMCPError.approvalFlowFailure
      }

      return .patch(
        .init(
          requestID: serverRequestID,
          originatingRequestID: originatingRequestID,
          threadID: threadID,
          message: message,
          requestedSchema: requestedSchema,
          codexEventID: codexEventID,
          reason: paramsObject["codex_reason"]?.stringValue,
          grantRoot: paramsObject["codex_grant_root"]?.stringValue,
          changes: changes,
        ))
    default:
      throw CodexMCPError.approvalFlowFailure
    }
  }

  static func originatingRequestID(fromApprovalParams params: CodexMCPJSONValue)
    -> CodexMCPRequestID?
  {
    guard
      let paramsObject = params.objectValue,
      let toolCallID = paramsObject["codex_mcp_tool_call_id"]?.stringValue
    else {
      return nil
    }

    return requestIDValue(fromToolCallID: toolCallID)
  }

  private static func stringArray(from values: [CodexMCPJSONValue]) -> [String]? {
    var strings: [String] = []
    for value in values {
      guard let string = value.stringValue else {
        return nil
      }
      strings.append(string)
    }
    return strings
  }
}
