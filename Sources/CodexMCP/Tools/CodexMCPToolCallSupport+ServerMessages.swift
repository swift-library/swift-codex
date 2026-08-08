import Foundation

extension CodexMCPToolCallSupport {
  static func serverMessage(
    method: String,
    params: CodexMCPJSONValue
  ) throws -> CodexMCPServerMessage? {
    guard method == "codex/event" else {
      return nil
    }

    let paramsObject = params.objectValue ?? [:]
    let metaObject = paramsObject["_meta"]?.objectValue
    let correlatedRequestID = requestIDValue(from: metaObject?["requestId"])
    let threadID = metaObject?["threadId"]?.stringValue

    let rawEvent: CodexMCPJSONValue
    if let nestedEvent = paramsObject["event"] {
      rawEvent = nestedEvent
    } else {
      var eventObject = paramsObject
      eventObject.removeValue(forKey: "_meta")
      rawEvent = .object(eventObject)
    }

    return CodexMCPServerMessage(
      method: method,
      rawEvent: rawEvent,
      requestID: correlatedRequestID,
      threadID: threadID,
    )
  }
}
