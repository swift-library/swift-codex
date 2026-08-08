import Foundation

extension CodexMCPToolCallSupport {
  static func requestIDValue(from value: CodexMCPJSONValue?) -> CodexMCPRequestID? {
    switch value {
    case .string(let string):
      return .string(string)
    case .integer(let integer):
      return .integer(integer)
    default:
      return nil
    }
  }

  static func requestIDValue(fromToolCallID toolCallID: String) -> CodexMCPRequestID {
    if let integer = Int64(toolCallID) {
      return .integer(integer)
    }

    return .string(toolCallID)
  }
}
