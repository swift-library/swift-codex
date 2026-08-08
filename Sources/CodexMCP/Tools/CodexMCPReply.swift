import Foundation

internal enum CodexMCPReply {
  static func arguments(from request: CodexMCPReplyRequest) -> CodexReplyToolArguments {
    CodexReplyToolArguments(request: request)
  }
}

internal struct CodexReplyToolArguments: Codable {
  let threadID: String
  let prompt: String

  init(request: CodexMCPReplyRequest) {
    threadID = request.threadID
    prompt = request.prompt
  }

  private enum CodingKeys: String, CodingKey {
    case threadID = "threadId"
    case prompt
  }
}
