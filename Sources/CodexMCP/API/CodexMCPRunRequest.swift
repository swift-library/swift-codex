import Foundation

/// Request for the Codex MCP `codex` tool.
public struct CodexMCPRunRequest: Equatable, Sendable {
  /// Approval policy accepted by the Codex MCP tool schema.
  public enum ApprovalPolicy: Equatable, Sendable {
    case untrusted
    case onFailure
    case onRequest
    case never

    internal var wireValue: String {
      switch self {
      case .untrusted:
        return "untrusted"
      case .onFailure:
        return "on-failure"
      case .onRequest:
        return "on-request"
      case .never:
        return "never"
      }
    }
  }

  /// Sandbox mode accepted by the Codex MCP tool schema.
  public enum SandboxMode: Equatable, Sendable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    internal var wireValue: String {
      switch self {
      case .readOnly:
        return "read-only"
      case .workspaceWrite:
        return "workspace-write"
      case .dangerFullAccess:
        return "danger-full-access"
      }
    }
  }

  /// Initial prompt for the Codex run.
  public var prompt: String
  /// Optional upstream model identifier.
  public var model: String?
  /// Optional upstream profile name.
  public var profile: String?
  /// Optional working directory.
  public var cwd: URL?
  /// Optional approval policy.
  public var approvalPolicy: ApprovalPolicy?
  /// Optional sandbox mode.
  public var sandboxMode: SandboxMode?
  /// Raw Codex config overrides.
  public var configOverrides: [String: CodexMCPJSONValue]
  /// Optional base instructions override.
  public var baseInstructions: String?
  /// Optional developer instructions override.
  public var developerInstructions: String?
  /// Optional compaction prompt override.
  public var compactPrompt: String?

  /// Creates a Codex MCP run request.
  public init(
    prompt: String,
    model: String? = nil,
    profile: String? = nil,
    cwd: URL? = nil,
    approvalPolicy: ApprovalPolicy? = nil,
    sandboxMode: SandboxMode? = nil,
    configOverrides: [String: CodexMCPJSONValue] = [:],
    baseInstructions: String? = nil,
    developerInstructions: String? = nil,
    compactPrompt: String? = nil,
  ) {
    self.prompt = prompt
    self.model = model
    self.profile = profile
    self.cwd = cwd
    self.approvalPolicy = approvalPolicy
    self.sandboxMode = sandboxMode
    self.configOverrides = configOverrides
    self.baseInstructions = baseInstructions
    self.developerInstructions = developerInstructions
    self.compactPrompt = compactPrompt
  }
}
