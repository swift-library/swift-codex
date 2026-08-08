import Foundation

internal enum CodexMCPRunCodex {
  static func arguments(from request: CodexMCPRunRequest) -> CodexToolArguments {
    CodexToolArguments(request: request)
  }
}

internal struct CodexToolArguments: Codable {
  let prompt: String
  let model: String?
  let profile: String?
  let cwd: String?
  let approvalPolicy: String?
  let sandbox: String?
  let config: [String: CodexMCPJSONValue]?
  let baseInstructions: String?
  let developerInstructions: String?
  let compactPrompt: String?

  init(request: CodexMCPRunRequest) {
    prompt = request.prompt
    model = request.model
    profile = request.profile
    cwd = request.cwd?.path
    approvalPolicy = request.approvalPolicy?.wireValue
    sandbox = request.sandboxMode?.wireValue
    config = request.configOverrides.isEmpty ? nil : request.configOverrides
    baseInstructions = request.baseInstructions
    developerInstructions = request.developerInstructions
    compactPrompt = request.compactPrompt
  }

  private enum CodingKeys: String, CodingKey {
    case prompt
    case model
    case profile
    case cwd
    case approvalPolicy = "approval-policy"
    case sandbox
    case config
    case baseInstructions = "base-instructions"
    case developerInstructions = "developer-instructions"
    case compactPrompt = "compact-prompt"
  }
}
