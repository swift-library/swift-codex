import Foundation

extension CodexMCPToolCallSupport {
  static func toolResult(from payload: CodexMCPJSONValue) throws -> CodexMCPToolResult {
    guard let payloadObject = payload.objectValue else {
      throw CodexMCPError.protocolFailure
    }

    let content = payloadObject["content"]?.arrayValue ?? []
    return try toolResult(
      from: CallToolResultPayload(
        content: content,
        structuredContent: payloadObject["structuredContent"],
        isError: payloadObject["isError"]?.boolValue,
      ))
  }

  private static func toolResult(from payload: CallToolResultPayload) throws -> CodexMCPToolResult {
    let rawStructuredContent = payload.structuredContent
    let structuredObject: [String: CodexMCPJSONValue]?
    if case .object(let object)? = rawStructuredContent {
      structuredObject = object
    } else {
      structuredObject = nil
    }

    let threadID = structuredObject?["threadId"]?.stringValue

    let extractedContent =
      structuredObject?["content"]?.stringValue
      ?? payload.content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()

    guard !extractedContent.isEmpty || payload.isError == true else {
      throw CodexMCPError.protocolFailure
    }

    if payload.isError != true, threadID == nil {
      throw CodexMCPError.protocolFailure
    }

    return CodexMCPToolResult(
      threadID: threadID,
      content: extractedContent,
      rawContentBlocks: payload.content,
      rawStructuredContent: rawStructuredContent,
      isError: payload.isError ?? false,
    )
  }
}

private struct CallToolResultPayload: Decodable {
  let content: [CodexMCPJSONValue]
  let structuredContent: CodexMCPJSONValue?
  let isError: Bool?

  private enum CodingKeys: String, CodingKey {
    case content
    case structuredContent
    case isError
  }
}
